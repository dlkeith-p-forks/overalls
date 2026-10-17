---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "10 — Version Compatibility"
status: complete
---

# Property discovery focus 10: Version compatibility

Eight candidates test only current accepted compatibility and refusal promises. The layers are distinct: `/api/control/v1` and Control envelope **v1**, Execution documents/runtime configuration **v4**, durable Lilly Store **v3**, image manifest **v4**, workspace source schema **v2**, its guest delivery envelope **v1**, and guest/private readiness documents **v1**. A permanent version refusal, transient 503/transport loss and an unproven in-flight effect require different oracles. Historical formats do not acquire compatibility merely because a current transport accepts their outer frame. Every proposed SDK assertion is **missing** per the [fresh assertion scan](../existing-assertions.md). These are property targets, not observed guarantees. This scratchbook-only diff has no architecture impact, changes no SUT contract, and ran no hosted/native test or mutant.

### control-v1-version-refusal-preserves-intent — Outer Control refusal

| | |
|---|---|
| **Type** | Safety, with positive reach marker |
| **Property** | A wrong Control upgrade version is refused before a socket/domain effect; a supported peer can reconnect and resynchronize durable state. |
| **Invariant** | `Always` **"Control v1 upgrade refusal creates no socket or domain effect"** on settled 426/401 refusals; `Reachable` **"Control v1 compatible reconnect resynchronized durable service state"** marks actual compatible recovery. |
| **Antithesis Angle** | Vary upgrade version/service/credential during pending work and Marshall outage, then replace with a compatible peer. |
| **Why It Matters** | An incompatible peer must not be silently treated as an authorized service, and a lost reply must remain unproven. [Evidence](property-candidates-10/control-v1-version-refusal-preserves-intent.md); P0, high confidence. |

**Open Questions:** Which supervised socket/task inventory can distinguish the refused upgrade from other clients?

### execution-v4-refuses-legacy-document — Inner execution version

| | |
|---|---|
| **Type** | Safety, with positive reach marker |
| **Property** | An unsupported inner Execution document cannot become executable intent or erase retained intent inside a valid outer v1 Control connection. |
| **Invariant** | `AlwaysOrUnreachable` **"Execution v4 refuses legacy authority without changing durable command"** on optional incompatible documents; `Reachable` **"Execution v4 accepted matching machine-bound session"** marks compatible session establishment. |
| **Antithesis Angle** | Inject v1/v3/v5 sessions and mixed command batches through an authenticated v1 socket, then reconnect with v4. |
| **Why It Matters** | A legacy receipt or wrong-machine session cannot grant current physical execution. [Evidence](property-candidates-10/execution-v4-refuses-legacy-document.md); P0, high confidence. |

**Open Questions:** Can a test-only peer inject inner documents through actual TLS/WebSocket service binding?

### store-v3-host-binding-survives-upgrade — Persistent host/format boundary

| | |
|---|---|
| **Type** | Safety |
| **Property** | Runtime startup refuses a foreign host or Store format before actors run, preserving stored commands; an optional legacy profile rename follows exact binding and preserves identity. |
| **Invariant** | `Always` **"Lilly Store v3 refuses foreign or changed host binding without reinterpretation"**; `AlwaysOrUnreachable` **"Bound profile rename preserves placement identity after Store v3 binding"** on legacy records. |
| **Antithesis Angle** | Restart with changed binding/command version, then replay valid v3 state and legacy profile records under real locks. |
| **Why It Matters** | Silent format/host reinterpretation or a misordered migration could turn retained receipts into wrong-host execution. [Evidence](property-candidates-10/store-v3-host-binding-survives-upgrade.md); P0, high confidence. |

**Open Questions:** Which startup seam changes configured binding across complete Runtime lifetimes while retaining real ownership?

### source-v2-capability-gates-admission — Image capability before allocation

| | |
|---|---|
| **Type** | Safety |
| **Property** | Sourced admission and first launch require a catalog-matching image-v4 manifest explicitly declaring source-v2 capability before allocation or host effects. |
| **Invariant** | `Always` **"Workspace source admission requires matching image v4 source-v2 capability"** over definite refusals and PostgreSQL/host inventories. |
| **Antithesis Angle** | Vary manifest version, artifact identity, declared source capability and idempotent retry around admission and launch. |
| **Why It Matters** | A stale capability can admit a VM that cannot receive its promised workspace source. [Evidence](property-candidates-10/source-v2-capability-gates-admission.md); P0, high confidence. |

**Open Questions:** Which registration path seeds obsolete manifests without bypassing real catalog validation?

### source-v2-delivery-envelope-v1-boot-bound — Guest handoff versions

| | |
|---|---|
| **Type** | Safety, with positive reach marker |
| **Property** | A delivered source-v2 journal requires matching v1 envelope, exact boot binding and nonce; source delivery failure does not prevent VM running readiness. |
| **Invariant** | `Always` **"Workspace source-v2 delivery accepts only matching v1 boot envelope"** at settled journals; `Reachable` **"Workspace source-v2 delivery accepted current boot without delaying readiness"** marks actual guest acceptance and running state. |
| **Antithesis Angle** | Delay/duplicate replies across a reboot or generation change, vary nested source and outer envelope versions. |
| **Why It Matters** | A stale guest or wrong delivery version could receive source identity for another boot. [Evidence](property-candidates-10/source-v2-delivery-envelope-v1-boot-bound.md); P1, medium-high confidence. |

**Open Questions:** Where can a controlled guest responder inject a wrong envelope through the actual vsock broker?

### private-readiness-v1-gates-new-execution — Versioned service dependency

| | |
|---|---|
| **Type** | Safety |
| **Property** | With private services enabled, new guest execution requires exact affirmative v1 Ziggy and Audi-private readiness at the configured host/role boundary. |
| **Invariant** | `AlwaysOrUnreachable` **"Private readiness v1 must match role and host before new guest execution"** on the optional configured path. |
| **Antithesis Angle** | Vary status version, role, host, health and socket availability while requesting a new start. |
| **Why It Matters** | A process-up signal or stale health document cannot establish private service authority for a new guest. [Evidence](property-candidates-10/private-readiness-v1-gates-new-execution.md); P0, medium-high confidence. |

**Open Questions:** Does the gate cover retained-start recovery as well as fresh starts?

### updater-versioned-health-before-promotion — Release promotion gate

| | |
|---|---|
| **Type** | Safety, with positive reach marker |
| **Property** | A changed candidate becomes `lastHealthy` only after staged compatibility/secret checks, migration, activation and exact v1 readiness from all enabled roles; identical active content with matching staged secrets may verify without migration. |
| **Invariant** | `Always` **"Updater promotes lastHealthy only after exact versioned role readiness"** at each state transition; `Reachable` **"Updater promoted changed candidate after exact v1 role health and migration"** marks a truly healthy changed release. |
| **Antithesis Angle** | Interrupt migrator/activation and vary one status socket's schema, host, role or secret while keeping units active. |
| **Why It Matters** | False promotion can retire a working release while serving roles or schema are unusable. [Evidence](property-candidates-10/updater-versioned-health-before-promotion.md); P0, medium-high confidence. |

**Open Questions:** Can native tests inject status documents while retaining each real service health implementation?

### guest-identity-cutover-preserves-uid-custody — Durable identity migration

| | |
|---|---|
| **Type** | Safety |
| **Property** | One-way guest-name cutover and email changes preserve GuestAccount UUID/UID custody and never reassign historical UIDs to another User. |
| **Invariant** | `Always` **"Guest identity cutover preserves UUID and UID custody across mailbox history"** against pre-cutover and settled database/guest inventories. |
| **Antithesis Angle** | Migrate colliding legacy names, retry allocation, edit email, retire and register the same email as a new User. |
| **Why It Matters** | UID reuse can attach retained guest files or credentials to a different account. [Evidence](property-candidates-10/guest-identity-cutover-preserves-uid-custody.md); P0, medium-high confidence. |

**Open Questions:** Which pre-cutover fixture retains historical rows and an independent sequence snapshot?

## Breadth and limits

Inspected outer Control upgrade/envelope/close/client, inner Execution codec and Lilly client/Runtime, Store and one-way profile migration, image manifest/source schema and guest delivery, private and guest readiness, updater stage/migrate/activate/verify, and durable guest identity ADR/migration/allocator. Related versioned protocols for relocation, terminal and SSH exist; the invariant here is closed peer refusal at their own actual boundaries, not an unsupported blanket rolling-compatibility promise. ADR-0142/0149/0158 and source contracts supply accepted intent, not current execution proof. Hosted services can test TLS, BEAM, PostgreSQL and ordinary files; actual vsock guest handoff needs TCG or native guest, and systemd updater/Firecracker/physical UID custody needs native machine evidence. No unresolved item is labeled a confirmed defect or requiring human input.
