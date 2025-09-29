// src/index.ts

export interface Env {
  OPENAI_API_KEY: string;
  CREDITS: KVNamespace;

  // App Store Server API credentials (App Store Connect → Users and Access → Keys → In-App Purchases)
  APPSTORE_ISSUER_ID: string;   // e.g. "57246542-96fe-1a63-e053-0824d011072a"
  APPSTORE_KEY_ID: string;      // 10-char key id
  APPSTORE_PRIVATE_KEY: string; // contents of the .p8 (BEGIN PRIVATE KEY ... END PRIVATE KEY)

  REVIEW_CODE: string;          // e.g. "APPREVIEW2025" (set via wrangler secret)
  REVIEW_GRANT_AMOUNT: string;  // e.g. "20" (as string; set via wrangler secret)
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

function json(status: number, data: any) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
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

// Accepts either raw 64-byte (r||s) or ASN.1 DER-encoded ECDSA signatures.
// Always returns JOSE base64url of raw (r||s).
function toJoseP256Signature(sig: Uint8Array): string {
  // Case A: already raw (r||s), 64 bytes
  if (sig.length === 64) {
    return base64urlEncode(sig);
  }

  // Case B: DER-encoded SEQUENCE { r INTEGER, s INTEGER }
  let offset = 0;
  if (sig[offset++] !== 0x30) throw new Error("Invalid DER: no sequence");

  // Read (possibly long-form) length
  let seqLen = sig[offset++];
  if (seqLen & 0x80) {
    const n = seqLen & 0x7f;
    let v = 0;
    for (let i = 0; i < n; i++) v = (v << 8) | sig[offset++];
    seqLen = v;
  }

  const expectInt = (label: "r" | "s") => {
    if (sig[offset++] !== 0x02) throw new Error(`Invalid DER: expecting integer for ${label}`);
    let len = sig[offset++];
    if (len & 0x80) {
      const n = len & 0x7f;
      let v = 0;
      for (let i = 0; i < n; i++) v = (v << 8) | sig[offset++];
      len = v;
    }
    const bytes = sig.slice(offset, offset + len);
    offset += len;
    return bytes;
  };

  const rDer = expectInt("r");
  const sDer = expectInt("s");

  const leftPad32 = (x: Uint8Array) => {
    // strip leading 0x00 if present then left-pad to 32 bytes
    let i = 0;
    while (i < x.length - 1 && x[i] === 0) i++;
    let y = x.slice(i);
    if (y.length > 32) throw new Error("Invalid ECDSA component length");
    if (y.length < 32) y = new Uint8Array([...new Uint8Array(32 - y.length), ...y]);
    return y;
  };

  const r = leftPad32(rDer);
  const s = leftPad32(sDer);

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
  // Be tolerant of secrets that include literal "\n"
  const normalized = pem.replace(/\\n/g, "\n").trim();
  const clean = normalized
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "")
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
    exp: now + 180,           // short-lived
    aud: "appstoreconnect-v1",
    bid: APP_BUNDLE_ID,       // <- REQUIRED for StoreKit Server API
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

  const sigJOSE = toJoseP256Signature(sigDER);
  return `${signingInput}.${sigJOSE}`;
}


// Call App Store Server API: Get Transaction Info (try prod, then sandbox) with detailed diagnostics.
async function getTransactionInfoFromApple(env: Env, transactionId: string): Promise<
  | { ok: true; json: any; environment: "PROD" | "SANDBOX" }
  | { ok: false; status: number; body: string; environment: "PROD" | "SANDBOX" }
> {
  async function call(
    host: "api.storekit.itunes.apple.com" | "api.storekit-sandbox.itunes.apple.com",
    environment: "PROD" | "SANDBOX"
  ) {
    const jwt = await signES256JWT(env);
    const url = `https://${host}/inApps/v1/transactions/${encodeURIComponent(transactionId)}`;

    const r = await fetch(url, {
      headers: {
        Authorization: `Bearer ${jwt}`,
        Accept: "application/json",
      },
    });

    const text = await r.text();
    if (r.ok) {
      try {
        const json = JSON.parse(text);
        if (json?.signedTransactionInfo) {
          return { ok: true as const, json, environment };
        }
        // OK but missing payload – treat as failure with details
        return { ok: false as const, status: r.status, body: text || "<empty>", environment };
      } catch {
        return { ok: false as const, status: r.status, body: text || "<non-json>", environment };
      }
    } else {
      return { ok: false as const, status: r.status, body: text || "<empty>", environment };
    }
  }

  // 1) Try production first
  const prod = await call("api.storekit.itunes.apple.com", "PROD");
  if (prod.ok) return prod;

  // 2) Fallback to sandbox
  const sbx = await call("api.storekit-sandbox.itunes.apple.com", "SANDBOX");
  if (sbx.ok) return sbx;

  // Return the "better" error (prefer sandbox when both failed)
  return sbx.status ? sbx : prod;
}

/* ================================
   Types for JWS payloads (client + Apple)
   ================================ */

// Minimal fields we care about from the client-sent JWS payload
type ClientSignedTransactionPayload = {
  transactionId: string;
  productId: string;
  bundleId: string;
  environment?: "Sandbox" | "Production";
  // plus more...
};

// From Apple response, we parse `signedTransactionInfo` JWS payload to confirm product/bundle.
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
    try {
      const url = new URL(req.url);
      const path = url.pathname;

      // --- Health check ---
      if (req.method === "GET" && path === "/health") {
        return json(200, { ok: true, ts: Date.now() });
      }

      // --- Credits: balance ---
      if (req.method === "GET" && path === "/credits/balance") {
        const deviceId = requireDeviceId(req);
        const balance = await getBalance(env, deviceId);
        const reservedRaw = await env.CREDITS.get(`device:${deviceId}:reserved`);
        const reserved = reservedRaw ? parseInt(reservedRaw, 10) || 0 : 0;
        console.log(
          `[balance] device=${deviceId} balance=${balance} reserved=${reserved} available=${Math.max(
            0,
            balance - reserved
          )}`
        );
        return json(200, {
          balance,
          reserved,
          available: Math.max(0, balance - reserved),
        });
      }

      // --- Credits: one-time review grant (self-serve for App Review) ---
      if (req.method === "POST" && path === "/credits/review-grant") {
        const deviceId = requireDeviceId(req);
        const body = await parseJSON<{ code?: string }>(req);
        const provided = (body.code || "").trim();
        const expected = (env.REVIEW_CODE || "").trim();
        console.log(`[review-grant] device=${deviceId} codeProvided=${!!provided}`);

        if (!provided || !expected || provided !== expected) {
          console.log(`[review-grant] bad_code device=${deviceId}`);
          return json(403, { error: "bad_code" });
        }

        const onceKey = `review_granted:${deviceId}`;
        if (await env.CREDITS.get(onceKey)) {
          const balance = await getBalance(env, deviceId);
          console.log(`[review-grant] already_granted device=${deviceId} balance=${balance}`);
          return json(200, { ok: true, granted: 0, already: true, balance });
        }

        const grant = parseInt(env.REVIEW_GRANT_AMOUNT || "20", 10) || 20;
        await addCredits(env, deviceId, grant);
        await env.CREDITS.put(onceKey, String(Date.now()));

        const balance = await getBalance(env, deviceId);
        console.log(`[review-grant] granted device=${deviceId} +${grant} newBalance=${balance}`);
        return json(200, { ok: true, granted: grant, balance });
      }

      // --- Credits: spend (server-authoritative) ---
      // Retained for backward compatibility with older clients.
      if (req.method === "POST" && path === "/credits/spend") {
        const deviceId = requireDeviceId(req);
        const body = await parseJSON<{ amount?: number }>(req);
        const amount = Math.max(1, Math.floor(body.amount ?? 1));

        const bal = await getBalance(env, deviceId);
        if (bal < amount) {
          return json(402, { error: "insufficient_credits", balance: bal });
        }

        await setBalance(env, deviceId, bal - amount);
        return json(200, { ok: true, balance: bal - amount });
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

        console.log(`[jobs/start] device=${deviceId} amount=${amount} reservedBefore=${reserved} bal=${bal}`);

        if (bal - reserved < amount) {
          return json(402, { error: "insufficient_credits", balance: bal, reserved });
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

        return json(200, { ok: true, jobId, reserved: reserved + amount, balance: bal });
      }

      // --- Jobs: commit (convert hold → debit) ---
      if (req.method === "POST" && path === "/jobs/commit") {
        const deviceId = requireDeviceId(req);
        const body = await parseJSON<{ jobId?: string }>(req);
        const jobId = (body.jobId || "").trim();
        if (!jobId) return json(400, { error: "missing_job_id" });

        const holdKey = `hold:${jobId}`;
        const raw = await env.CREDITS.get(holdKey);
        if (!raw) return json(200, { ok: true, already: true }); // expired or already handled

        let hold: any;
        try {
          hold = JSON.parse(raw);
        } catch {
          return json(409, { error: "bad_hold" });
        }
        if (hold.state !== "pending") return json(200, { ok: true, already: true });

        if (hold.deviceId !== deviceId) {
          return json(403, { error: "device_mismatch" });
        }
        const amount = Math.max(1, Math.floor(hold.amount || 1));

        // Adjust reserved ↓ and balance ↓
        const bal = await getBalance(env, deviceId);
        const reservedRaw = await env.CREDITS.get(`device:${deviceId}:reserved`);
        const reserved = reservedRaw ? parseInt(reservedRaw, 10) || 0 : 0;

        console.log(
          `[jobs/commit] device=${deviceId} jobId=${jobId} amount=${amount} balBefore=${bal} reservedBefore=${reserved}`
        );

        await setBalance(env, deviceId, Math.max(0, bal - amount));
        await env.CREDITS.put(`device:${deviceId}:reserved`, String(Math.max(0, reserved - amount)));

        // Mark committed (keep a short record)
        hold.state = "committed";
        hold.committedAt = Date.now();
        await env.CREDITS.put(holdKey, JSON.stringify(hold), { expirationTtl: 3600 });

        const newBal = await getBalance(env, deviceId);
        return json(200, { ok: true, balance: newBal });
      }

      // --- Jobs: cancel (release hold) ---
      if (req.method === "POST" && path === "/jobs/cancel") {
        const deviceId = requireDeviceId(req);
        const body = await parseJSON<{ jobId?: string }>(req);
        const jobId = (body.jobId || "").trim();
        if (!jobId) return json(400, { error: "missing_job_id" });

        const holdKey = `hold:${jobId}`;
        const raw = await env.CREDITS.get(holdKey);
        if (!raw) return json(200, { ok: true, already: true });

        let hold: any;
        try {
          hold = JSON.parse(raw);
        } catch {
          return json(409, { error: "bad_hold" });
        }
        if (hold.state !== "pending") return json(200, { ok: true, already: true });

        if (hold.deviceId !== deviceId) {
          return json(403, { error: "device_mismatch" });
        }
        const amount = Math.max(1, Math.floor(hold.amount || 1));

        // reserved ↓
        const reservedRaw = await env.CREDITS.get(`device:${deviceId}:reserved`);
        const reserved = reservedRaw ? parseInt(reservedRaw, 10) || 0 : 0;

        console.log(
          `[jobs/cancel] device=${deviceId} jobId=${jobId} amount=${amount} reservedBefore=${reserved}`
        );

        await env.CREDITS.put(`device:${deviceId}:reserved`, String(Math.max(0, reserved - amount)));

        // Mark cancelled (or delete)
        hold.state = "cancelled";
        hold.cancelledAt = Date.now();
        await env.CREDITS.put(holdKey, JSON.stringify(hold), { expirationTtl: 900 });

        const bal = await getBalance(env, deviceId);
        return json(200, { ok: true, balance: bal });
      }

      // --- New (iOS 18+): Credits: redeem via signed transactions (StoreKit 2 JWS) ---
      if (req.method === "POST" && path === "/credits/redeem-signed") {
        const deviceId = requireDeviceId(req);
        const body = await parseJSON<{ signedTransactions?: string[] }>(req);
        const signed = Array.isArray(body.signedTransactions) ? body.signedTransactions : [];
        console.log(`[redeem-signed] device=${deviceId} signedCount=${signed.length}`);

        if (signed.length === 0) {
          return json(400, { error: "missing_signed_transactions" });
        }

        const missing = ["APPSTORE_ISSUER_ID", "APPSTORE_KEY_ID", "APPSTORE_PRIVATE_KEY"].filter(
          (k) => !(env as any)[k]
        );
        if (missing.length) {
          console.error(`[redeem-signed] server_not_configured missing=${missing.join(",")}`);
          return json(500, { error: "server_not_configured", missing });
        }

        let granted = 0;
        const perTx: any[] = [];

        for (const jws of signed) {
          const parts = jws.split(".");
          if (parts.length !== 3) {
            console.log("[redeem-signed] bad_jws_parts");
            perTx.push({ error: "bad_jws_parts" });
            continue;
          }

          let clientPayload: ClientSignedTransactionPayload | null = null;
          try {
            clientPayload = JSON.parse(stringFromBase64url(parts[1]));
          } catch {
            perTx.push({ error: "bad_client_payload" });
            continue;
          }

          const txId = (clientPayload?.transactionId || "").trim();
          const claimedProductId = (clientPayload?.productId || "").trim();
          const claimedBundleId = (clientPayload?.bundleId || "").trim();
          const envHintSandbox = clientPayload?.environment === "Sandbox";
          console.log(
            `[redeem-signed] client txId=${txId} productId=${claimedProductId} bundle=${claimedBundleId} env=${clientPayload?.environment}`
          );

          if (!txId) {
            perTx.push({ error: "missing_txId" });
            continue;
          }

          const infoRes = await getTransactionInfoFromApple(env, txId);
          if (!infoRes.ok) {
            // Map common statuses to actionable client errors
            const status = infoRes.status;
            let code = "apple_verification_unavailable";
            if (status === 401 || status === 403) code = "apple_jwt_invalid";          // bad ISS/KID/KEY or expired clock skew
            else if (status === 404) code = "transaction_not_found";                    // wrong env or bad txId
            else if (status === 429) code = "apple_rate_limited";                        // retry later
            console.log(
              `[redeem-signed] txId=${txId} env=${infoRes.environment} status=${status} code=${code} body=${(infoRes.body || "").slice(0, 400)}`
            );
            return new Response(JSON.stringify({ error: code, status, environmentTried: infoRes.environment }), {
              status: status === 404 ? 404 : status === 401 || status === 403 ? 502 : 503,
              headers: { "content-type": "application/json", "cache-control": "no-store" },
            });
          }

          // happy path
          const info = infoRes.json; // has signedTransactionInfo


          // Decode Apple's signedTransactionInfo JWS payload
          const appleParts = String(info.signedTransactionInfo).split(".");
          let applePayload: AppleSignedTransactionPayload | null = null;
          try {
            applePayload = JSON.parse(stringFromBase64url(appleParts[1]));
          } catch {
            perTx.push({ txId, error: "bad_apple_payload" });
            continue;
          }

          const appleTxId = (applePayload?.transactionId || "").trim();
          const appleProductId = (applePayload?.productId || "").trim();
          const appleBundleId = (applePayload?.bundleId || "").trim();

          console.log(
            `[redeem-signed] apple txId=${appleTxId} productId=${appleProductId} bundle=${appleBundleId}`
          );

          if (!appleTxId || !appleProductId || !appleBundleId) {
            perTx.push({ txId, error: "apple_fields_missing" });
            continue;
          }
          if (appleBundleId !== APP_BUNDLE_ID) {
            perTx.push({ txId, error: "bundle_mismatch", got: appleBundleId, want: APP_BUNDLE_ID });
            continue;
          }
          if (appleTxId !== txId) {
            perTx.push({ txId, error: "tx_mismatch", appleTxId });
            continue;
          }

          // Idempotency
          const txKey = `iap:${appleTxId}`;
          const already = await env.CREDITS.get(txKey);
          if (already) {
            console.log(`[redeem-signed] already processed txId=${appleTxId}`);
            perTx.push({ txId, ok: true, duplicate: true, productId: appleProductId, credits: 0 });
            continue;
          }

          const credits = PRODUCT_TO_CREDITS[appleProductId] ?? 0;
          await env.CREDITS.put(
            txKey,
            JSON.stringify({ productId: appleProductId, creditsGranted: credits, ts: Date.now() })
          );
          console.log(`[redeem-signed] will grant=${credits} for productId=${appleProductId}`);

          if (credits > 0) {
            await addCredits(env, deviceId, credits);
            granted += credits;
          }

          perTx.push({ txId, ok: true, productId: appleProductId, credits });
        }

        const balance = await getBalance(env, deviceId);
        console.log(`[redeem-signed] device=${deviceId} grantedTotal=${granted} newBalance=${balance}`);
        return json(200, { ok: true, granted, perTx, balance });
      }

      // --- Diagnostics: App Store key sanity (does NOT leak private key) ---
      if (req.method === "GET" && path === "/diag/appstore") {
        const kid = (env.APPSTORE_KEY_ID || "").trim();
        const iss = (env.APPSTORE_ISSUER_ID || "").trim();
        const pem = (env.APPSTORE_PRIVATE_KEY || "").trim();
        const pemOk =
          pem.startsWith("-----BEGIN PRIVATE KEY-----") &&
          pem.endsWith("-----END PRIVATE KEY-----");

        return Response.json(
          {
            hasIssuerId: !!iss,
            issuerIdLen: iss.length,
            keyId: kid ? `${kid.slice(0, 3)}…${kid.slice(-2)}` : null, // redacted
            pemLooksValid: pemOk,
            pemPreview: pemOk
              ? `${pem.split("\n")[0]} … ${pem.split("\n").slice(-1)[0]}`
              : null,
          },
          { headers: { "cache-control": "no-store" } },
        );
      }

      // --- Diagnostics: Show the JWT header/payload we would send (safe, redacted) ---
      if (req.method === "GET" && path === "/diag/appstore/jwt") {
        if (!env.APPSTORE_ISSUER_ID || !env.APPSTORE_KEY_ID || !env.APPSTORE_PRIVATE_KEY) {
          return Response.json({ ok: false, error: "missing_credentials" }, { headers: { "cache-control": "no-store" }});
        }

        // Build a JWT exactly like the real one (but return only safe bits)
        const now = Math.floor(Date.now() / 1000);
        const header = { alg: "ES256", kid: env.APPSTORE_KEY_ID, typ: "JWT" };
        const payload = {
          iss: env.APPSTORE_ISSUER_ID,
          iat: now,
          exp: now + 180,
          aud: "appstoreconnect-v1",
          bid: APP_BUNDLE_ID,
        };

        // Sign for real so that the size matches what Apple will see
        let jwt: string;
        try {
          jwt = await signES256JWT(env);
        } catch (e: any) {
          return Response.json({ ok: false, error: "sign_failed", detail: String(e?.message || e) }, { headers: { "cache-control": "no-store" }});
        }

        const parts = jwt.split(".");
        const encHeader = parts[0] ?? "";
        const encPayload = parts[1] ?? "";
        const sig = parts[2] ?? "";

        // Redact signature fully; return decoded header/payload for sanity
        let decHeader: any = null, decPayload: any = null;
        try { decHeader = JSON.parse(stringFromBase64url(encHeader)); } catch {}
        try { decPayload = JSON.parse(stringFromBase64url(encPayload)); } catch {}

        return Response.json({
          ok: true,
          now,
          skewSeconds: 0, // Workers time should be accurate; included for your reference
          header: decHeader,
          payload: decPayload,
          tokenByteLength: jwt.length,
          signaturePreview: sig ? `${sig.slice(0,6)}…${sig.slice(-6)}` : null
        }, { headers: { "cache-control": "no-store" }});
      }

      // --- Diagnostics: Call Apple with our JWT to see status from PROD/SANDBOX ---
      if (req.method === "GET" && path === "/diag/appstore/ping") {
        if (!env.APPSTORE_ISSUER_ID || !env.APPSTORE_KEY_ID || !env.APPSTORE_PRIVATE_KEY) {
          return Response.json({ ok: false, error: "missing_credentials" }, { headers: { "cache-control": "no-store" }});
        }

        // Pick host via query ?env=prod|sandbox (default: sandbox)
        const q = new URL(req.url).searchParams;
        const which = (q.get("env") || "sandbox").toLowerCase();
        const host = which === "prod" ? "api.storekit.itunes.apple.com" : "api.storekit-sandbox.itunes.apple.com";

        // We’ll call a known-bad tx id so Apple returns 404 if JWT is valid (that’s good!)
        const txId = "0";
        const url = `https://${host}/inApps/v1/transactions/${txId}`;
        const jwt = await signES256JWT(env);

        let status = 0, text = "";
        try {
          const r = await fetch(url, {
            headers: { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" },
          });
          status = r.status;
          text = await r.text();
        } catch (e: any) {
          return Response.json({ ok: false, error: "fetch_failed", detail: String(e?.message || e) }, { headers: { "cache-control": "no-store" }});
        }

        // If JWT is accepted, Apple usually returns 404 for txId=0. 401 means token problem.
        return Response.json({
          ok: true,
          host,
          status,
          bodyPreview: text.slice(0, 200),
          hint: status === 404
            ? "JWT accepted (good). 404 is expected for a bogus transactionId."
            : (status === 401 ? "JWT rejected. Check Issuer ID, Key ID, key type (IAP), clock skew, and claims." : "See bodyPreview for details.")
        }, { headers: { "cache-control": "no-store" }});
      }


      // --- Legacy (< iOS 18): Credits: redeem via App Store receipt (base64) ---
      if (req.method === "POST" && path === "/credits/redeem") {
        const deviceId = requireDeviceId(req);
        const body = await parseJSON<{ receipt?: string }>(req);
        const receipt = (body.receipt || "").trim();
        console.log(`[redeem-receipt] device=${deviceId} receiptLen=${receipt.length}`);

        if (!receipt || receipt.length < 100) {
          return json(400, { error: "missing_receipt" });
        }

        let data = await verifyReceiptWithApple(receipt, false);
        if (data?.status === 21007) {
          console.log(`[redeem-receipt] Apple says sandbox → retrying sandbox`);
          data = await verifyReceiptWithApple(receipt, true);
        }

        if (!data || typeof data.status !== "number" || data.status !== 0) {
          console.log(`[redeem-receipt] verify_failed status=${data?.status}`);
          return json(400, { error: "verify_failed", status: data?.status ?? -1 });
        }

        const bundleIdInReceipt: string | undefined = data?.receipt?.bundle_id;
        console.log(`[redeem-receipt] bundle in receipt=${bundleIdInReceipt}`);
        if (bundleIdInReceipt !== APP_BUNDLE_ID) {
          console.log(
            `[redeem-receipt] bundle_mismatch got=${bundleIdInReceipt} want=${APP_BUNDLE_ID}`
          );
          return json(400, {
            error: "bundle_mismatch",
            got: bundleIdInReceipt ?? null,
            want: APP_BUNDLE_ID,
          });
        }

        const items: any[] = [
          ...(Array.isArray(data?.latest_receipt_info) ? data.latest_receipt_info : []),
          ...(Array.isArray(data?.receipt?.in_app) ? data.receipt.in_app : []),
        ];
        console.log(`[redeem-receipt] items count=${items.length}`);

        let granted = 0;
        for (const it of items) {
          const txId = String(it?.transaction_id ?? it?.original_transaction_id ?? "").trim();
          const productId = String(it?.product_id ?? "").trim();
          if (!txId || !productId) continue;

          const txKey = `iap:${txId}`;
          const already = await env.CREDITS.get(txKey);
          if (already) {
            console.log(`[redeem-receipt] already processed txId=${txId}`);
            continue;
          }

          const credits = PRODUCT_TO_CREDITS[productId] ?? 0;
          await env.CREDITS.put(
            txKey,
            JSON.stringify({ productId, creditsGranted: credits, ts: Date.now() })
          );
          console.log(
            `[redeem-receipt] will grant=${credits} for productId=${productId} txId=${txId}`
          );
          if (credits > 0) granted += credits;
        }

        if (granted > 0) await addCredits(env, deviceId, granted);
        const balance = await getBalance(env, deviceId);
        console.log(
          `[redeem-receipt] device=${deviceId} grantedTotal=${granted} newBalance=${balance} env=${data?.environment}`
        );

        return json(200, {
          ok: true,
          granted,
          balance,
          environment: data?.environment ?? "Unknown",
        });
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
    } catch (err: any) {
      console.error("UNCAUGHT", err?.stack || String(err));
      return json(500, { error: "server_exception", detail: String(err?.message || err) });
    }
  },
} satisfies ExportedHandler<Env>;
