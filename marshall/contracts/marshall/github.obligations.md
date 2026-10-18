---
modules: [Marshall.GitHub, Marshall.GitHub.AuditEvent, Marshall.GitHub.AuthorizationAttempt, Marshall.GitHub.Connection, Marshall.GitHub.Exclusion, Marshall.GitHub.Grant, Marshall.GitHub.Persistence, Marshall.GitHub.Provider, Marshall.GitHub.RefreshAttempt, Marshall.GitHub.RequestLease, Marshall.GitHub.RestoreEpoch, Marshall.GitHub.Worker]
---

# GitHub identity custody obligations

## Purpose

These contracts cover behavior observed in the BEAM test VM against PostgreSQL
with a synthetic OAuth provider. They do not establish live GitHub consent or
revocation, browser behavior, native guest isolation, or deployment acceptance.
ADR-0198 and the GitHub service handbook retain those separate evidence limits.

### marshall.github.I1 — OAuth state is one-use and login-bound
- **scope:** `Marshall.GitHub.begin_authorization/2`, `callback/4`, and `status/1`
- **must:** A callback MUST require its initiating live stored login and consume its state at most once. Status MUST expose neither OAuth credentials nor the PKCE verifier.
- **kind:** security
- **status:** active

### marshall.github.I2 — Disconnect withdraws private authority and preserves public access
- **scope:** `Marshall.GitHub.authorization/2`, `renew/5`, and `disconnect/1`
- **must:** Disconnect MUST fence an issued credential generation before returning. The old private pin MUST refuse renewal, and subsequent public admission MUST be anonymous without credentials.
- **kind:** security
- **status:** active

### marshall.github.I3 — Restore epochs invalidate credentials exactly once
- **scope:** `Marshall.GitHub.apply_restore_epoch!/1`
- **must:** A new restore epoch MUST atomically clear encrypted credentials, ceremonies and request pins and require browser reconnection. Reapplying the same epoch MUST NOT increment generations again.
- **kind:** security
- **status:** active
