// src/index.ts
export interface Env {
  OPENAI_API_KEY: string;
  CREDITS: KVNamespace;
}

// ------- Helpers -------
function getDeviceId(req: Request): string {
  const id = req.headers.get("X-Device-Id")?.trim();
  if (!id)
    throw new Response(JSON.stringify({ error: "missing_device_id" }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  return id;
}

async function json<T = any>(req: Request): Promise<T> {
  try {
    // @ts-ignore - generic for developer ergonomics
    return await req.json<T>();
  } catch {
    throw new Response(JSON.stringify({ error: "invalid_json" }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  }
}

async function getBalance(env: Env, deviceId: string): Promise<number> {
  const raw = await env.CREDITS.get(`device:${deviceId}`);
  return raw ? parseInt(raw, 10) || 0 : 0;
}
async function setBalance(env: Env, deviceId: string, v: number) {
  await env.CREDITS.put(`device:${deviceId}`, String(Math.max(0, v)));
}

// Apple verifyReceipt helper
async function verifyReceiptWithApple(
  receiptBase64: string,
  useSandbox: boolean
): Promise<any> {
  const url = useSandbox
    ? "https://sandbox.itunes.apple.com/verifyReceipt"
    : "https://buy.itunes.apple.com/verifyReceipt";

  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      "receipt-data": receiptBase64,
      // For subscriptions you'd add "password": <app-shared-secret>
      "exclude-old-transactions": true,
    }),
  });
  let data: any;
  try {
    data = await res.json();
  } catch {
    data = null;
  }
  return data;
}

// Map product ids -> credit amounts (match your iOS product IDs)
const PRODUCT_TO_CREDITS: Record<string, number> = {
  "io.robinfederico.InputMaximizer.credits_10": 10,
  "io.robinfederico.InputMaximizer.credits_50": 50,
  "io.robinfederico.InputMaximizer.credits_200": 200,
};

// ------- Worker -------
export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;

    // --- Health ---
    if (req.method === "GET" && path === "/health") {
      return new Response(JSON.stringify({ ok: true, ts: Date.now() }), {
        headers: { "content-type": "application/json", "cache-control": "no-store" },
      });
    }

    // --- Balance ---
    if (req.method === "GET" && path === "/credits/balance") {
      const deviceId = getDeviceId(req);
      const balance = await getBalance(env, deviceId);
      return Response.json({ balance }, { headers: { "cache-control": "no-store" } });
    }

    // --- Spend (server authoritative) ---
    if (req.method === "POST" && path === "/credits/spend") {
      const deviceId = getDeviceId(req);
      const body = await json<{ amount?: number }>(req);
      const amount = Math.max(1, Math.floor(body.amount ?? 1));
      const bal = await getBalance(env, deviceId);
      if (bal < amount) {
        return new Response(
          JSON.stringify({ error: "insufficient_credits", balance: bal }),
          { status: 402, headers: { "content-type": "application/json" } }
        );
      }
      await setBalance(env, deviceId, bal - amount);
      return Response.json({ ok: true, balance: bal - amount });
    }

    // --- Redeem (App Store receipt -> credits) ---
    if (req.method === "POST" && path === "/credits/redeem") {
      const deviceId = getDeviceId(req);
      const body = await json<{ receipt?: string }>(req);
      const receipt = (body.receipt || "").trim();

      if (!receipt || receipt.length < 100) {
        return new Response(JSON.stringify({ error: "missing_receipt" }), {
          status: 400,
          headers: { "content-type": "application/json" },
        });
      }

      // 1) Try production
      let data = await verifyReceiptWithApple(receipt, false);

      // If Apple says it's a sandbox receipt (21007), retry in sandbox
      if (data?.status === 21007) {
        data = await verifyReceiptWithApple(receipt, true);
      }

      if (!data || typeof data.status !== "number" || data.status !== 0) {
        // Pass Apple's status back for debugging
        return new Response(
          JSON.stringify({ error: "verify_failed", status: data?.status ?? -1 }),
          { status: 400, headers: { "content-type": "application/json" } }
        );
      }

      // Where Apple lists purchases:
      // - consumables/non-consumables: data.receipt.in_app[]
      // - sometimes latest_receipt_info[] (esp. subscriptions)
      const items: any[] = [
        ...(Array.isArray(data.latest_receipt_info) ? data.latest_receipt_info : []),
        ...(Array.isArray(data?.receipt?.in_app) ? data.receipt.in_app : []),
      ];

      let granted = 0;

      for (const it of items) {
        const txId = String(
          it?.transaction_id ?? it?.original_transaction_id ?? ""
        ).trim();
        const productId = String(it?.product_id ?? "").trim();
        if (!txId || !productId) continue;

        // Idempotency: only grant once per transaction
        const seenKey = `iap:${txId}`;
        const already = await env.CREDITS.get(seenKey);
        if (already) continue;

        const credits = PRODUCT_TO_CREDITS[productId] ?? 0;
        if (credits <= 0) {
          // Unknown product id: record it to avoid reprocessing, but grant nothing
          await env.CREDITS.put(seenKey, JSON.stringify({ productId, granted: 0 }));
          continue;
        }

        granted += credits;

        // Mark redeemed (store some metadata for audit/debug)
        await env.CREDITS.put(
          seenKey,
          JSON.stringify({
            productId,
            credits,
            ts: Date.now(),
          })
        );
      }

      const balKey = `device:${deviceId}`;
      const current = Number((await env.CREDITS.get(balKey)) ?? "0");
      const newBalance = current + granted;

      if (granted > 0) {
        await env.CREDITS.put(balKey, String(newBalance));
      }

      return Response.json(
        { granted, balance: newBalance },
        { headers: { "cache-control": "no-store" } }
      );
    }

    // --- Chat proxy -> OpenAI /v1/chat/completions ---
    if (req.method === "POST" && path === "/chat") {
      // Require a device id (for tracing/rate limiting later)
      void getDeviceId(req);

      const body = await json<any>(req); // e.g. { model: "gpt-5-nano", messages: [...] }
      const r = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          authorization: `Bearer ${env.OPENAI_API_KEY}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
      });

      if (!r.ok) {
        const errText = await r.text();
        return new Response(errText || '{"error":"upstream_error"}', {
          status: r.status,
          headers: { "content-type": "application/json" },
        });
      }

      const data = await r.text();
      return new Response(data, { headers: { "content-type": "application/json" } });
    }

    // --- TTS proxy -> OpenAI /v1/audio/speech (MP3) ---
    if (req.method === "POST" && path === "/tts") {
      void getDeviceId(req);

      const wanted = await json<{
        text: string;
        language?: string;
        speed?: "regular" | "slow";
        voice?: string;
        format?: "mp3" | "wav" | "flac";
      }>(req);

      const instruction =
        wanted.speed === "slow"
          ? `Speak naturally and slowly${wanted.language ? ` in ${wanted.language}` : ""}.`
          : `Speak naturally${wanted.language ? ` in ${wanted.language}` : ""}.`;

      const upstreamBody = {
        model: "gpt-4o-mini-tts",
        voice: wanted.voice || "shimmer",
        input: wanted.text,
        format: wanted.format || "mp3",
        instructions: instruction,
      };

      const r = await fetch("https://api.openai.com/v1/audio/speech", {
        method: "POST",
        headers: {
          authorization: `Bearer ${env.OPENAI_API_KEY}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(upstreamBody),
      });

      if (!r.ok) {
        const errText = await r.text();
        return new Response(errText || '{"error":"upstream_error"}', {
          status: r.status,
          headers: { "content-type": "application/json" },
        });
      }

      return new Response(r.body, {
        headers: { "content-type": "audio/mpeg", "cache-control": "no-store" },
      });
    }

    return new Response("Not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
