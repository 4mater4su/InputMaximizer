// src/index.ts

export interface Env {
  OPENAI_API_KEY: string;
  CREDITS: KVNamespace;
}

/* ================================
   Config
   ================================ */

// Enforce that receipts come from this exact app
const APP_BUNDLE_ID = "io.robinfederico.InputMaximizer";

// Map App Store product IDs to how many credits they grant
const PRODUCT_TO_CREDITS: Record<string, number> = {
  "io.robinfederico.InputMaximizer.credits_10": 10,
  "io.robinfederico.InputMaximizer.credits_50": 50,
  "io.robinfederico.InputMaximizer.credits_200": 200,
};

/* ================================
   Helpers
   ================================ */

function requireDeviceId(req: Request): string {
  const id = req.headers.get("X-Device-Id")?.trim();
  if (!id) {
    throw new Response(JSON.stringify({ error: "missing_device_id" }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  }
  return id;
}

async function parseJSON<T = any>(req: Request): Promise<T> {
  try {
    // @ts-ignore – ergonomic generic
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

async function addCredits(env: Env, deviceId: string, delta: number) {
  const current = await getBalance(env, deviceId);
  await setBalance(env, deviceId, current + delta);
}

// Verify an App Store receipt with Apple.
// If `useSandbox` is true, hits the sandbox endpoint; otherwise production.
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
      // Add "password": <shared secret> for auto-renewable subscriptions.
      "exclude-old-transactions": true,
    }),
  });

  let data: any = null;
  try {
    data = await res.json();
  } catch {
    // leave null – handled by caller
  }
  return data;
}

/* ================================
   Handler
   ================================ */

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;

    // --- Health check ---
    if (req.method === "GET" && path === "/health") {
      return new Response(JSON.stringify({ ok: true, ts: Date.now() }), {
        headers: { "content-type": "application/json", "cache-control": "no-store" },
      });
    }

    // --- Credits: balance ---
    if (req.method === "GET" && path === "/credits/balance") {
      const deviceId = requireDeviceId(req);
      const balance = await getBalance(env, deviceId);
      return Response.json({ balance }, { headers: { "cache-control": "no-store" } });
    }

    // --- Credits: spend (server-authoritative) ---
    if (req.method === "POST" && path === "/credits/spend") {
      const deviceId = requireDeviceId(req);
      const body = await parseJSON<{ amount?: number }>(req);
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

    // --- Credits: redeem (App Store receipt -> credits) ---
    if (req.method === "POST" && path === "/credits/redeem") {
      const deviceId = requireDeviceId(req);
      const body = await parseJSON<{ receipt?: string }>(req);
      const receipt = (body.receipt || "").trim();

      if (!receipt || receipt.length < 100) {
        return new Response(JSON.stringify({ error: "missing_receipt" }), {
          status: 400,
          headers: { "content-type": "application/json" },
        });
      }

      // 1) Ask Apple (prod first)
      let data = await verifyReceiptWithApple(receipt, false);

      // If Apple says it's sandbox (21007), retry against sandbox
      if (data?.status === 21007) {
        data = await verifyReceiptWithApple(receipt, true);
      }

      if (!data || typeof data.status !== "number" || data.status !== 0) {
        // Surface Apple's status for easier debugging in-app
        return new Response(
          JSON.stringify({ error: "verify_failed", status: data?.status ?? -1 }),
          { status: 400, headers: { "content-type": "application/json" } }
        );
      }

      // 2) Bundle guard – ensure receipt belongs to our app
      const bundleIdInReceipt: string | undefined = data?.receipt?.bundle_id;
      if (bundleIdInReceipt !== APP_BUNDLE_ID) {
        return new Response(
          JSON.stringify({
            error: "bundle_mismatch",
            got: bundleIdInReceipt ?? null,
            want: APP_BUNDLE_ID,
          }),
          { status: 400, headers: { "content-type": "application/json" } }
        );
      }

      // 3) Collect in-app purchase line items from receipt payload
      const items: any[] = [
        ...(Array.isArray(data?.latest_receipt_info) ? data.latest_receipt_info : []),
        ...(Array.isArray(data?.receipt?.in_app) ? data.receipt.in_app : []),
      ];

      let granted = 0;
      for (const it of items) {
        const txId = String(
          it?.transaction_id ?? it?.original_transaction_id ?? ""
        ).trim();
        const productId = String(it?.product_id ?? "").trim();
        if (!txId || !productId) continue;

        // Idempotency: grant at most once per transaction id
        const txKey = `iap:${txId}`;
        const already = await env.CREDITS.get(txKey);
        if (already) continue;

        const credits = PRODUCT_TO_CREDITS[productId] ?? 0;

        // Record the transaction as processed (even if product unknown)
        await env.CREDITS.put(
          txKey,
          JSON.stringify({
            productId,
            creditsGranted: credits,
            ts: Date.now(),
          })
        );

        if (credits > 0) {
          granted += credits;
        }
      }

      // 4) Update device balance
      if (granted > 0) {
        await addCredits(env, deviceId, granted);
      }
      const balance = await getBalance(env, deviceId);

      return Response.json(
        {
          ok: true,
          granted,
          balance,
          environment: data?.environment ?? "Unknown",
        },
        { headers: { "cache-control": "no-store" } }
      );
    }

    // --- Chat proxy -> OpenAI /v1/chat/completions ---
    if (req.method === "POST" && path === "/chat") {
      // Require device id (for tracing/rate limiting later)
      void requireDeviceId(req);

      const body = await parseJSON<any>(req);
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
      void requireDeviceId(req);

      const wanted = await parseJSON<{
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
