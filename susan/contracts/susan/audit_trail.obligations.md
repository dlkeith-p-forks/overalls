---
modules: [Susan.Audit, Susan.Audit.AuditEntry, Susan.Audit.Chain, Susan.Audit.Log, Susan.Maintenance.Prune, Susan.Operator, Susan.Relay, Susan.Relay.InstallIdentity, Susan.Relay.KeyDenial, Susan.Relay.UnregisteredToken, Susan.Relay.DeliveryReceipt]
---

# Audit Trail obligations

## Purpose

Susan's own append-only, hash-chained audit trail with 90-day retention, and the relay resources it records (ADR-0224).

### susan.audit_trail.I1 — Append-only in the database
- **scope:** `audit_entries` table, `Susan.Audit.AuditEntry`
- **must:** The database MUST refuse UPDATE, TRUNCATE and DELETE of audit rows outside the retention prune, and the resource MUST define no update or destroy action.
- **kind:** security
- **status:** active

### susan.audit_trail.I2 — Hash chain detects tampering
- **scope:** `Susan.Audit.Chain`, `Susan.Audit.Log`
- **must:** Each row MUST chain to its predecessor's digest, and verification MUST fail for an edited, removed or reordered interior row.
- **kind:** security
- **status:** active

### susan.audit_trail.I3 — Prune is retention-bounded and audited
- **scope:** `Susan.Audit.Log`, `Susan.Maintenance.Prune`
- **must:** The prune MUST delete only rows older than 90 days and MUST append a prune entry with the deleted count.
- **kind:** functional
- **status:** active

### susan.audit_trail.I4 — Install identity lifecycle
- **scope:** `Susan.Relay.InstallIdentity`
- **must:** Install identities MUST move unknown -> trusted <-> rate_limited, reach blocked from any state and leave blocked only by operator unblock.
- **kind:** functional
- **status:** active

### susan.audit_trail.I5 — No request content at rest
- **scope:** every Susan table
- **must:** No provider token, push key, ciphertext, nonce, deployment host or source address MAY appear in any Susan table.
- **kind:** security
- **status:** active
