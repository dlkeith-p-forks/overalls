---
modules: [Susan.PushKey, Susan.Keyring, Susan.Keys, Susan.Config, Susan.Credentials, Susan.Provider, Susan.Provider.WNS]
---

# Push Keys obligations

## Purpose

Issued push keys are AEAD envelopes binding the provider token, deployment and issue time under a rotating keyring (ADR-0224). Susan stores no token or envelope.

### susan.push_keys.I1 — Envelopes are tamper-evident
- **scope:** `Susan.PushKey`
- **must:** Any modified envelope byte MUST be refused as an unknown key.
- **kind:** security
- **status:** active

### susan.push_keys.I2 — Rotation and expiry
- **scope:** `Susan.PushKey`, `Susan.Keyring`
- **must:** Keys sealed under a retained keyring id MUST still open after rotation, and every key MUST expire 90 days after issue.
- **kind:** functional
- **status:** active

### susan.push_keys.I3 — Issuance is closed and bound
- **scope:** `Susan.Keys`
- **must:** Issuance MUST refuse unknown fields, unconfigured application ids and malformed tokens, and the issued key MUST bind the requested deployment.
- **kind:** security
- **status:** active

### susan.push_keys.I4 — Secrets come only from custodied files
- **scope:** `Susan.Config`, `Susan.Credentials`
- **must:** Startup MUST refuse group- or world-readable or symlinked secret files with one fixed error.
- **kind:** security
- **status:** active

### susan.push_keys.I5 — WNS channels are confined to WNS
- **scope:** `Susan.Keys`, `Susan.Provider`, `Susan.Provider.WNS`
- **must:** A WNS push key MUST be issued only for an `https` channel URI on port 443 under `.notify.windows.com` with no userinfo or fragment (ADR-0236), and a sealed WNS key whose channel fails that shape MUST be rejected before any provider request.
- **kind:** security
- **status:** active
