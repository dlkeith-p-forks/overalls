---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
---

# G8: operational boundaries and diagnostic independence

This repo-only gap pass adds four independent candidate properties. The [fresh assertion scan](../../existing-assertions.md) found no implemented Antithesis SDK assertions. Source and accepted decisions state contracts to test; source presence and native fixture presence are not a current passing campaign. No retired harness, history or external system claim was used. No architecture, protocol, runtime or handbook content changes here; this is a verification research artifact. ADR-0104, ADR-0045, ADR-0041/0044 and ADR-0149 are the affected accepted claims.

| Canonical slug | Type / priority | Primary planned SDK assertion and unique literal message | Evidence | Open question |
| --- | --- | --- | --- | --- |
| `lyra-guest-update-fences-executor-handoff` | Safety, P1 | `Always`: **"Lyra guest update never runs unverified or overlapping executors"** | [Candidate](operations/lyra-guest-update-fences-executor-handoff.md) | Can a real guest fixture control candidate registration and interrupt the seed at each durable handoff? |
| `host-enrollment-receipt-follows-live-health` | Safety, P1 | `Always`: **"Host enrollment receipt follows authenticated binding and live role health"** | [Candidate](operations/host-enrollment-receipt-follows-live-health.md) | Can the native fixture independently inspect Marshall operation identity, Lilly polling and physical storage identity through retries? |
| `runtime-secret-bundle-complete-or-previous` | Safety, P1 | `Always`: **"Runtime secret bundle publication is complete or retains the previous bundle"** | [Candidate](operations/runtime-secret-bundle-complete-or-previous.md) | Can a native crash schedule cut before and after directory exchange while preserving a read-only bundle observer? |
| `diagnostic-outage-preserves-authorized-user-effect` | Liveness, P1 | `Sometimes(condition)`: **"Authorized guest effect completes during a finite diagnostic outage"** | [Candidate](operations/diagnostic-outage-preserves-authorized-user-effect.md) | Which hosted or native topology faults recorder, spool and Collector independently while retaining the real control and guest path? |

These do not duplicate the recorder ticket, trace archive or quota rows: those concern measurement custody. The last row requires a separately witnessed physical/user effect. They do not duplicate the fleet updater's candidate promotion or role restoration rows: Lyra runs inside the guest, while enrollment and secret publication establish different authority and custody boundaries. A diagnostic ACK is never a lifecycle completion prerequisite under ADR-0149. Bound progress only after valid user authority, real service dependencies and a finite explicitly released fault; refuse to treat unknown measurement as a failed user effect.

Native NixOS/guest tests and generated property tests exist in these areas, but this pass ran no tests and makes no current native or hosted execution claim. The topology is still a design. The candidates record implementation seams and honest coverage limits; full deployment, physical host failure and secret confidentiality cannot be inferred from source reading.
