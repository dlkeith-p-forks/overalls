---
modules: [Susan.Poke, Susan.Poke.Machine, Susan.Poke.Request, Susan.Replay, Susan.RateLimiter, Susan.TokenBucket, Susan.HTTP, Susan.Provider, Susan.Provider.APNs, Susan.Provider.FCM]
---

# Poke Pipeline obligations

## Purpose

The signed poke pipeline of ADR-0224: strict decoding, authentication by push key and install signature, replay refusal, rate limiting and at most one provider notification per delivery id. Native TLS, real APNs/FCM and multi-host behaviour remain governed by the NixOS machine tests and the ADR.

### susan.poke_pipeline.I1 — Sends only after every check
- **scope:** `Susan.Poke.Machine`
- **must:** A provider send MUST be commanded only after validation, authentication, replay, rate admission and delivery claim, with at most two sends and exactly one response per request.
- **kind:** security
- **status:** active

### susan.poke_pipeline.I2 — Unauthenticated refusals are indistinguishable
- **scope:** `Susan.Poke`, `Susan.HTTP`
- **must:** An unopenable push key and a bad install signature MUST both answer 404 with the same body as a malformed request and MUST NOT write to the database.
- **kind:** security
- **status:** active

### susan.poke_pipeline.I3 — Retries never double-notify
- **scope:** `Susan.Poke`
- **must:** A poke repeating an already delivered delivery id from the same install MUST answer 204 without another provider request.
- **kind:** functional
- **status:** active

### susan.poke_pipeline.I4 — Replays and stale pokes are refused
- **scope:** `Susan.Replay`, `Susan.Poke`
- **must:** A reused nonce or an issued_at more than 300 seconds from Susan's clock MUST be refused before any provider effect.
- **kind:** security
- **status:** active

### susan.poke_pipeline.I5 — Per-key burst limit
- **scope:** `Susan.RateLimiter`, `Susan.TokenBucket`
- **must:** A push key MUST be admitted at most ten times in a burst, then answered 429 with a positive Retry-After.
- **kind:** non-functional
- **status:** active

### susan.poke_pipeline.I6 — Content-free provider messages
- **scope:** `Susan.Provider.APNs`, `Susan.Provider.FCM`
- **must:** Provider payloads MUST carry only the opaque ciphertext, the collapse id, the fixed kind and fixed localization keys; APNs MUST set mutable-content and FCM MUST be data-only.
- **kind:** security
- **status:** active
