// src/index.ts
export interface Env {
  OPENAI_API_KEY: string;
  CREDITS: KVNamespace;
}

// Helpers
function getDeviceId(req: Request): string {
  const id = req.headers.get("X-Device-Id")?.trim();
  if (!id) throw new Response(JSON.stringify({ error: "missing_device_id" }), { status: 400 });
  return id;
}
async function json<T = any>(req: Request): Promise<T> {
  try { return await req.json<T>(); }
  catch { throw new Response(JSON.stringify({ error: "invalid_json" }), { status: 400 }); }
}
async function getBalance(env: Env, deviceId: string): Promise<number> {
  const raw = await env.CREDITS.get(`device:${deviceId}`);
  return raw ? parseInt(raw, 10) || 0 : 0;
}
async function setBalance(env: Env, deviceId: string, v: number) {
  await env.CREDITS.put(`device:${deviceId}`, String(Math.max(0, v)));
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;

    // Simple health check
    if (req.method === "GET" && path === "/health") {
      return new Response(JSON.stringify({ ok: true, ts: Date.now() }), {
        headers: { "content-type": "application/json" },
      });
    }

    // Balance
    if (req.method === "GET" && path === "/credits/balance") {
      const deviceId = getDeviceId(req);
      const balance = await getBalance(env, deviceId);
      return Response.json({ balance });
    }

    // Spend credits (server-authoritative)
    if (req.method === "POST" && path === "/credits/spend") {
      const deviceId = getDeviceId(req);
      const body = await json<{ amount?: number }>(req);
      const amount = Math.max(1, Math.floor(body.amount ?? 1));
      const bal = await getBalance(env, deviceId);
      if (bal < amount) {
        return new Response(JSON.stringify({ error: "insufficient_credits", balance: bal }), {
          status: 402,
          headers: { "content-type": "application/json" },
        });
      }
      await setBalance(env, deviceId, bal - amount);
      return Response.json({ ok: true, balance: bal - amount });
    }

    // Chat proxy -> OpenAI /v1/chat/completions
    if (req.method === "POST" && path === "/chat") {
      // Just require a device id (for rate limiting / tracing if you need it later)
      void getDeviceId(req);

      const body = await json<any>(req); // Expect { model: "gpt-5-nano", messages: [...] }
      const r = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "authorization": `Bearer ${env.OPENAI_API_KEY}`,
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

      // Return OpenAI's JSON as-is (your iOS code already parses it)
      const data = await r.text();
      return new Response(data, { headers: { "content-type": "application/json" } });
    }

    // TTS proxy -> OpenAI /v1/audio/speech  (returns MP3)
    if (req.method === "POST" && path === "/tts") {
      // Require device id
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
          "authorization": `Bearer ${env.OPENAI_API_KEY}`,
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
      // Stream audio back
      return new Response(r.body, {
        headers: { "content-type": "audio/mpeg", "cache-control": "no-store" },
      });
    }

    return new Response("Not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
