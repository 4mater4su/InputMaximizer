// src/index.ts

export interface Env {
  OPENAI_API_KEY: string;
  CREDITS: KVNamespace;

  // App Store Server API credentials (App Store Connect → Users and Access → Keys → In-App Purchases)
  APPSTORE_ISSUER_ID: string;   // e.g. "57246542-96fe-1a63-e053-0824d011072a"
  APPSTORE_KEY_ID: string;      // 10-char key id
  APPSTORE_PRIVATE_KEY: string; // contents of the .p8 (BEGIN PRIVATE KEY ... END PRIVATE KEY)
}

/* ================================
   Config
   ================================ */

// Enforce that receipts/transactions come from this exact app
const APP_BUNDLE_ID = "io.robinfederico.InputMaximizer";

// Map App Store product IDs to how many credits they grant
const PRODUCT_TO_CREDITS: Record<string, number> = {
  "io.robinfederico.InputMaximizer.credits_10": 10,
  "io.robinfederico.InputMaximizer.credits_50": 50,
  "io.robinfederico.InputMaximizer.credits_200": 200,
};

/* ================================
   Small utilities
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

/* ================================
   Receipt verification (legacy, < iOS 18)
   ================================ */

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
      // Add "password": <shared secret> for auto-renewable subscriptions if needed.
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
   JWS helpers (StoreKit 2 signed tx)
   ================================ */

function base64urlEncode(buf: Uint8Array): string {
  let s = btoa(String.fromCharCode(...buf));
  return s.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function base64urlFromString(s: string): string {
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function stringFromBase64url(b64url: string): string {
  const pad = "=".repeat((4 - (b64url.length % 4)) % 4);
  const b64 = b64url.replace(/-/g, "+").replace(/_/g, "/") + pad;
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

// Convert DER-encoded ECDSA signature to JOSE (raw r|s, base64url)
function derToJoseSignature(der: Uint8Array): string {
  // Minimal ASN.1 DER parser for ECDSA-Sig-Value: SEQUENCE { r INTEGER, s INTEGER }
  // Returns 64-byte raw signature (r|s), each padded to 32 bytes for P-256.
  let offset = 0;
  if (der[offset++] !== 0x30) throw new Error("Invalid DER: no sequence");
  const seqLen = der[offset++];
  void seqLen; // not used further in this minimal parser

  const rMarker = der[offset++];
  if (rMarker !== 0x02) throw new Error("Invalid DER: expecting integer for r");
  let rLen = der[offset++];
  let r = der.slice(offset, offset + rLen);
  offset += rLen;

  const sMarker = der[offset++];
  if (sMarker !== 0x02) throw new Error("Invalid DER: expecting integer for s");
  let sLen = der[offset++];
  let s = der.slice(offset, offset + sLen);
  offset += sLen;

  // Remove any leading 0x00 sign bytes, then left-pad to 32
  const trim = (x: Uint8Array) => {
    let i = 0;
    while (i < x.length - 1 && x[i] === 0) i++;
    x = x.slice(i);
    if (x.length > 32) throw new Error("Invalid length for ECDSA component");
    if (x.length < 32) {
      const pad = new Uint8Array(32 - x.length);
      x = new Uint8Array([...pad, ...x]);
    }
    return x;
  };

  r = trim(r);
  s = trim(s);

  const raw = new Uint8Array(64);
  raw.set(r, 0);
  raw.set(s, 32);
  return base64urlEncode(raw);
}

/* ================================
   App Store Server API auth (ES256 JWT)
   ================================ */

// Import EC private key (PKCS8 from .p8 PEM) into WebCrypto
async function importAppleECPrivateKey(pem: string): Promise<CryptoKey> {
  const clean = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\r?\n|\r/g, "")
    .trim();

  const binary = Uint8Array.from(atob(clean), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    binary.buffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
}

async function signES256JWT(env: Env): Promise<string> {
  const header = {
    alg: "ES256",
    kid: env.APPSTORE_KEY_ID,
    typ: "JWT",
  };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: env.APPSTORE_ISSUER_ID,
    iat: now,
    exp: now + 180, // short-lived
    aud: "appstoreconnect-v1",
  };

  const encHeader = base64urlFromString(JSON.stringify(header));
  const encPayload = base64urlFromString(JSON.stringify(payload));
  const signingInput = `${encHeader}.${encPayload}`;

  const key = await importAppleECPrivateKey(env.APPSTORE_PRIVATE_KEY);
  const sigDER = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      new TextEncoder().encode(signingInput)
    )
  );

  const sigJOSE = derToJoseSignature(sigDER);
  return `${signingInput}.${sigJOSE}`;
}

// Call App Store Server API: Get Transaction Info
async function getTransactionInfoFromApple(env: Env, transactionId: string): Promise<any | null> {
  const jwt = await signES256JWT(env);
  const r = await fetch(
    `https://api.storekit.itunes.apple.com/inApps/v1/transactions/${encodeURIComponent(
      transactionId
    )}`,
    {
      headers: {
        Authorization: `Bearer ${jwt}`,
        "Content-Type": "application/json",
      },
    }
  );
  if (!r.ok) {
    return null;
  }
  return await r.json();
}

/* ================================
   Types for JWS payloads (client + Apple)
   ================================ */

// Minimal fields we care about from the client-sent JWS payload
type ClientSignedTransactionPayload = {
  transactionId: string;
  productId: string;
  bundleId: string;
  // also contains environment, purchaseDate, etc., but we don't rely on them here
};

// From Apple response, we'll parse `signedTransactionInfo` JWS payload to confirm product/bundle.
type AppleSignedTransactionPayload = {
  transactionId: string;
  bundleId: string;
  productId: string;
  // plus many others…
};

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
      const reservedRaw = await env.CREDITS.get(`device:${deviceId}:reserved`);
      const reserved = reservedRaw ? parseInt(reservedRaw, 10) || 0 : 0;
      return Response.json(
        { balance, reserved, available: Math.max(0, balance - reserved) },
        { headers: { "cache-control": "no-store" } }
      );
    }

    // --- Credits: spend (server-authoritative) ---
    // Retained for backward compatibility with older clients.
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

    // --- Jobs: start (place a hold) ---
    if (req.method === "POST" && path === "/jobs/start") {
      const deviceId = requireDeviceId(req);
      const body = await parseJSON<{ amount?: number; jobId?: string; ttlSeconds?: number }>(req);
      const amount = Math.max(1, Math.floor(body.amount ?? 1));
      const jobId = (body.jobId || crypto.randomUUID()).trim();
      const ttl = Math.min(Math.max(300, body.ttlSeconds ?? 1800), 86400); // 5 min .. 24h

      const bal = await getBalance(env, deviceId);
      const reservedRaw = await env.CREDITS.get(`device:${deviceId}:reserved`);
      const reserved = reservedRaw ? parseInt(reservedRaw, 10) || 0 : 0;

      if (bal - reserved < amount) {
        return new Response(
          JSON.stringify({ error: "insufficient_credits", balance: bal, reserved }),
          { status: 402, headers: { "content-type": "application/json" } }
        );
      }

      // Reserve
      await env.CREDITS.put(`device:${deviceId}:reserved`, String(reserved + amount));
      const holdKey = `hold:${jobId}`;
      const expiresAt = Date.now() + ttl * 1000;
      await env.CREDITS.put(
        holdKey,
        JSON.stringify({ deviceId, amount, state: "pending", expiresAt }),
        { expirationTtl: ttl }
      );

      return Response.json({ ok: true, jobId, reserved: reserved + amount, balance: bal });
    }

    // --- Jobs: commit (convert hold → debit) ---
    if (req.method === "POST" && path === "/jobs/commit") {
      const deviceId = requireDeviceId(req);
      const body = await parseJSON<{ jobId?: string }>(req);
      const jobId = (body.jobId || "").trim();
      if (!jobId)
        return new Response(JSON.stringify({ error: "missing_job_id" }), {
          status: 400,
          headers: { "content-type": "application/json" },
        });

      const holdKey = `hold:${jobId}`;
      const raw = await env.CREDITS.get(holdKey);
      if (!raw) return Response.json({ ok: true, already: true }); // expired or already handled

      let hold: any;
      try {
        hold = JSON.parse(raw);
      } catch {
        return new Response(JSON.stringify({ error: "bad_hold" }), {
          status: 409,
          headers: { "content-type": "application/json" },
        });
      }
      if (hold.state !== "pending") return Response.json({ ok: true, already: true });

      if (hold.deviceId !== deviceId) {
        return new Response(JSON.stringify({ error: "device_mismatch" }), {
          status: 403,
          headers: { "content-type": "application/json" },
        });
      }
      const amount = Math.max(1, Math.floor(hold.amount || 1));

      // Adjust reserved ↓ and balance ↓
      const bal = await getBalance(env, deviceId);
      const reservedRaw = await env.CREDITS.get(`device:${deviceId}:reserved`);
      const reserved = reservedRaw ? parseInt(reservedRaw, 10) || 0 : 0;

      await setBalance(env, deviceId, Math.max(0, bal - amount));
      await env.CREDITS.put(`device:${deviceId}:reserved`, String(Math.max(0, reserved - amount)));

      // Mark committed (keep a short record)
      hold.state = "committed";
      hold.committedAt = Date.now();
      await env.CREDITS.put(holdKey, JSON.stringify(hold), { expirationTtl: 3600 });

      const newBal = await getBalance(env, deviceId);
      return Response.json({ ok: true, balance: newBal });
    }

    // --- Jobs: cancel (release hold) ---
    if (req.method === "POST" && path === "/jobs/cancel") {
      const deviceId = requireDeviceId(req);
      const body = await parseJSON<{ jobId?: string }>(req);
      const jobId = (body.jobId || "").trim();
      if (!jobId)
        return new Response(JSON.stringify({ error: "missing_job_id" }), {
          status: 400,
          headers: { "content-type": "application/json" },
        });

      const holdKey = `hold:${jobId}`;
      const raw = await env.CREDITS.get(holdKey);
      if (!raw) return Response.json({ ok: true, already: true });

      let hold: any;
      try {
        hold = JSON.parse(raw);
      } catch {
        return new Response(JSON.stringify({ error: "bad_hold" }), {
          status: 409,
          headers: { "content-type": "application/json" },
        });
      }
      if (hold.state !== "pending") return Response.json({ ok: true, already: true });

      if (hold.deviceId !== deviceId) {
        return new Response(JSON.stringify({ error: "device_mismatch" }), {
          status: 403,
          headers: { "content-type": "application/json" },
        });
      }
      const amount = Math.max(1, Math.floor(hold.amount || 1));

      // reserved ↓
      const reservedRaw = await env.CREDITS.get(`device:${deviceId}:reserved`);
      const reserved = reservedRaw ? parseInt(reservedRaw, 10) || 0 : 0;
      await env.CREDITS.put(`device:${deviceId}:reserved`, String(Math.max(0, reserved - amount)));

      // Mark cancelled (or delete)
      hold.state = "cancelled";
      hold.cancelledAt = Date.now();
      await env.CREDITS.put(holdKey, JSON.stringify(hold), { expirationTtl: 900 });

      const bal = await getBalance(env, deviceId);
      return Response.json({ ok: true, balance: bal });
    }

    // --- New (iOS 18+): Credits: redeem via signed transactions (StoreKit 2 JWS) ---
    if (req.method === "POST" && path === "/credits/redeem-signed") {
      const deviceId = requireDeviceId(req);
      const body = await parseJSON<{ signedTransactions?: string[] }>(req);
      const signed = Array.isArray(body.signedTransactions) ? body.signedTransactions : [];
      if (signed.length === 0) {
        return new Response(JSON.stringify({ error: "missing_signed_transactions" }), {
          status: 400,
          headers: { "content-type": "application/json" },
        });
      }

      let granted = 0;

      for (const jws of signed) {
        const parts = jws.split(".");
        if (parts.length !== 3) continue;

        // Extract client payload (untrusted) to read tx id + product id
        let clientPayload: ClientSignedTransactionPayload | null = null;
        try {
          clientPayload = JSON.parse(stringFromBase64url(parts[1]));
        } catch {
          continue;
        }
        const txId = (clientPayload?.transactionId || "").trim();
        const claimedProductId = (clientPayload?.productId || "").trim();
        const claimedBundleId = (clientPayload?.bundleId || "").trim();
        if (!txId || !claimedProductId || !claimedBundleId) continue;

        // Authoritative verification with Apple
        const info = await getTransactionInfoFromApple(env, txId);
        if (!info || typeof info.signedTransactionInfo !== "string") {
          continue; // Could not verify
        }

        // Parse Apple's signedTransactionInfo (JWS) payload (trusted source)
        const appleParts = info.signedTransactionInfo.split(".");
        if (appleParts.length !== 3) continue;
        let applePayload: AppleSignedTransactionPayload | null = null;
        try {
          applePayload = JSON.parse(stringFromBase64url(appleParts[1]));
        } catch {
          continue;
        }

        const appleTxId = (applePayload?.transactionId || "").trim();
        const appleProductId = (applePayload?.productId || "").trim();
        const appleBundleId = (applePayload?.bundleId || "").trim();
        if (!appleTxId || !appleProductId || !appleBundleId) continue;

        // Hard gates
        if (appleBundleId !== APP_BUNDLE_ID) continue;
        if (appleTxId !== txId) continue;

        // Idempotency: process each transaction once
        const txKey = `iap:${appleTxId}`;
        const already = await env.CREDITS.get(txKey);
        if (already) continue;

        const credits = PRODUCT_TO_CREDITS[appleProductId] ?? 0;

        // Record the transaction as processed (even if product unknown)
        await env.CREDITS.put(
          txKey,
          JSON.stringify({
            productId: appleProductId,
            creditsGranted: credits,
            ts: Date.now(),
          })
        );

        if (credits > 0) {
          granted += credits;
        }
      }

      // Update device balance
      if (granted > 0) {
        await addCredits(env, deviceId, granted);
      }
      const balance = await getBalance(env, deviceId);

      return Response.json(
        { ok: true, granted, balance },
        { headers: { "cache-control": "no-store" } }
      );
    }

    // --- Legacy (< iOS 18): Credits: redeem via App Store receipt (base64) ---
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
