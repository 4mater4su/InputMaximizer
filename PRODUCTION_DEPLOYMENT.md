# Production Deployment Guide

## Summary of Security Changes

Your backend has been hardened for production with the following critical improvements:

### 1. ✅ Job Token Authentication
- **What**: Server-issued cryptographic tokens (64-char hex) for each generation job
- **Why**: Prevents unauthorized API calls to `/chat` and `/tts` endpoints
- **How**: 
  - Client calls `/jobs/start` → receives `jobId` + `jobToken`
  - Client must send both in headers (`X-Job-Id`, `X-Job-Token`) for all AI calls
  - Server validates token, device match, expiry, and pending state before processing

### 2. ✅ Rate Limiting
- **What**: Per-device request limits using KV-based counters
- **Limits**:
  - `/chat`: 60 requests/minute per device
  - `/tts`: 120 requests/minute per device  
  - `/credits/review-grant`: 3 attempts/hour per device
- **Why**: Prevents abuse, brute force attacks, and API cost spikes

### 3. ✅ Review Grant Protection
- **What**: Multi-layer abuse prevention for promo codes
- **Protections**:
  - Failed attempt tracking (5 failures = 24h block)
  - One-time redemption per device
  - Rate limited to 3 attempts/hour
  - Automatic penalty clearing on success

### 4. ✅ Admin-Protected Diagnostics
- **What**: Diagnostic endpoints now require `X-Admin-Secret` header
- **Endpoints**: `/diag/appstore`, `/diag/appstore/jwt`, `/diag/appstore/ping`
- **Why**: Prevents information disclosure and unauthorized Apple API calls

---

## Deployment Steps

### A. Backend (Cloudflare Worker)

#### 1. Set Required Secrets

```bash
cd inputmax-proxy

# Set admin secret for diagnostics (generate a strong random value)
wrangler secret put ADMIN_SECRET
# Enter: <paste a long random string, e.g., from `openssl rand -hex 32`>

# Verify existing secrets are set:
wrangler secret list
```

**Required secrets** (should already be configured):
- `OPENAI_API_KEY`
- `APPSTORE_ISSUER_ID`
- `APPSTORE_KEY_ID`
- `APPSTORE_PRIVATE_KEY`
- `REVIEW_CODE`
- `REVIEW_GRANT_AMOUNT` (default: "20")
- `INITIAL_GRANT` (default: "3", optional)
- `ADMIN_SECRET` (NEW - set above)

#### 2. Deploy to Production

```bash
# Test locally first (optional)
wrangler dev

# Deploy to production
wrangler deploy
```

#### 3. Verify Deployment

Test the health endpoint:
```bash
curl https://inputmax-proxy.inputmax.workers.dev/health
# Expected: {"ok":true,"ts":...}
```

Test diagnostics (requires admin secret):
```bash
curl -H "X-Admin-Secret: YOUR_ADMIN_SECRET" \
  https://inputmax-proxy.inputmax.workers.dev/diag/appstore
# Expected: JSON with hasIssuerId, keyId preview, etc.
```

---

### B. iOS Client (Already Updated)

The Swift client has been updated to:
1. Receive `jobToken` from `/jobs/start`
2. Send both `jobId` and `jobToken` in headers to `/chat` and `/tts`
3. No changes needed to existing credit flow (start/commit/cancel)

**No additional client changes required** — just rebuild and test.

---

## Testing Checklist

### Backend Validation

- [ ] Health check responds: `GET /health`
- [ ] Balance endpoint works: `GET /credits/balance` with `X-Device-Id`
- [ ] Job start returns token: `POST /jobs/start` → verify `jobToken` in response
- [ ] Chat requires job credentials: `POST /chat` without headers → 401
- [ ] TTS requires job credentials: `POST /tts` without headers → 401
- [ ] Rate limit enforced: spam `/chat` → eventually 429
- [ ] Review grant limited: try 4+ wrong codes → 403 blocked
- [ ] Diagnostics protected: `GET /diag/appstore` without secret → 401 or 503

### End-to-End Flow

1. **Start Job**:
   ```bash
   curl -X POST https://inputmax-proxy.inputmax.workers.dev/jobs/start \
     -H "X-Device-Id: test-device-123" \
     -H "Content-Type: application/json" \
     -d '{"amount":1}'
   ```
   → Save `jobId` and `jobToken` from response

2. **Call Chat** (with job credentials):
   ```bash
   curl -X POST https://inputmax-proxy.inputmax.workers.dev/chat \
     -H "X-Device-Id: test-device-123" \
     -H "X-Job-Id: <jobId>" \
     -H "X-Job-Token: <jobToken>" \
     -H "Content-Type: application/json" \
     -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Hello"}]}'
   ```
   → Should return OpenAI response

3. **Commit Job**:
   ```bash
   curl -X POST https://inputmax-proxy.inputmax.workers.dev/jobs/commit \
     -H "X-Device-Id: test-device-123" \
     -H "Content-Type: application/json" \
     -d '{"jobId":"<jobId>"}'
   ```
   → Credits debited

4. **Test iOS App**: Generate a lesson end-to-end

---

## Security Best Practices

### 1. Rotate Secrets Regularly
- `REVIEW_CODE`: Change after App Review completes
- `ADMIN_SECRET`: Rotate quarterly or after any suspected exposure

### 2. Monitor Usage
```bash
# Check Cloudflare dashboard for:
# - Request spikes (potential abuse)
# - Error rates (401/429 = blocked attackers)
# - KV read/write ops (credit ledger load)
```

### 3. Rate Limit Tuning
If legitimate users hit rate limits, adjust in `index.ts`:
```typescript
// Line ~991: Chat rate limit
const rateLimit = await checkRateLimit(env, `chat:${deviceId}`, 60, 60);
// Increase from 60 to e.g., 100 requests/minute

// Line ~1026: TTS rate limit  
const rateLimit = await checkRateLimit(env, `tts:${deviceId}`, 120, 60);
// Increase from 120 to e.g., 200 requests/minute
```

### 4. Initial Grant Policy
Set `INITIAL_GRANT` to control free credits for new users:
```bash
wrangler secret put INITIAL_GRANT
# Enter: 3 (or 5, 10, etc.)
```

---

## Remaining Considerations

### Non-Critical (Future Improvements)

1. **Atomic Credits with Durable Objects**
   - Current: KV-based (eventual consistency, race conditions possible)
   - Better: Durable Object per device for atomic operations
   - When: If you see race condition bugs or need strong consistency

2. **Device Attestation (App Attest)**
   - Current: Device ID is client-generated UUID
   - Better: Apple App Attest or DeviceCheck for proof-of-app
   - When: If you see device ID farming or need stronger identity

3. **Structured Logging & Alerts**
   - Current: `console.log` statements
   - Better: Structured logs to external service (Sentry, Logtail)
   - When: For production monitoring and incident response

4. **Idempotency Keys for Jobs**
   - Current: Client can retry job start
   - Better: Client-provided idempotency key to prevent duplicate holds
   - When: If you see double-debits from network retries

---

## Rollback Plan

If issues arise in production:

1. **Quick Rollback**:
   ```bash
   # List recent deployments
   wrangler deployments list
   
   # Rollback to previous version
   wrangler rollback --deployment-id <previous-id>
   ```

2. **Emergency: Disable Token Enforcement**:
   - Edit `index.ts`: Comment out `await requireValidJob(...)` lines
   - Quick deploy: `wrangler deploy`
   - ⚠️ Only for emergency — this removes all protection

---

## Success Criteria

Your backend is production-ready when:

- ✅ All secrets are configured
- ✅ Deployment succeeds without errors
- ✅ Health check responds
- ✅ End-to-end lesson generation works in iOS app
- ✅ Unauthorized requests return 401 (no job token)
- ✅ Rate limits trigger after spam (429 errors)
- ✅ Diagnostics require admin secret

---

## Support & Monitoring

### Cloudflare Dashboard
- Workers Analytics: https://dash.cloudflare.com → Workers & Pages → inputmax-proxy
- Check: Request volume, error rates, CPU time, KV operations

### Logs
```bash
# Tail live logs during testing
wrangler tail
```

### Key Metrics to Watch
- **401 errors**: Blocked unauthorized attempts (good)
- **429 errors**: Rate limit hits (tune if too aggressive)
- **402 errors**: Insufficient credits (expected user flow)
- **500 errors**: Server bugs (investigate immediately)

---

## Contact

For questions or issues:
1. Check Cloudflare Workers logs: `wrangler tail`
2. Review this document's testing checklist
3. Test in `wrangler dev` (local mode) first
4. Deploy incrementally (test → staging → prod)

**You're ready for production! 🚀**

