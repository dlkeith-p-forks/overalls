# terminal-create-reply-loss-one-pty

P0; high confidence; safety. SDK callsites **missing** per [fresh scan](../existing-assertions.md). `Always` **"Terminal create replay retains one guest PTY and one opened receipt"**: one immutable request ID can bind at most one guest PTY, Marshall Session, and `opened` audit receipt; duplicate matching create replies return that same registry identity. A conflicting actor/VM/parameter retry must refuse. `Always` checks each settled request history; timeout remains pending/uncertain until guest query resolves it.

Source: `marshall/lib/marshall/terminal/creation.ex:8-79` locks request and VM, hashes user/TERM, reuses ready/pending opening and refuses changed replay; `:96-159` commits Session, opened receipt and ready Opening in one transaction and reuses ready Session on duplicate. `marshall/lib/marshall/terminal/authority.ex:93-131` reserves before sending create and returns pending on ambiguous result. `marshall/lib/marshall/terminal/reconciler.ex:165-178` queries guest by request ID and completes a running PTY. `marshall/lib/marshall/terminal/opening.ex:26-40,98-107` binds immutable metadata without terminal bytes. The guest PTY implementation is needed as the effect witness; DB rows alone cannot prove one PTY.

History/oracle: use a real authenticated terminal client against Marshall, real host stream and a TCG guest terminal daemon. Record attempted IDs, guest PTY identity/process/creation count through guest-owned query, API session IDs and a separate PostgreSQL snapshot of Opening/Session/Event. Drop the guest-create response, kill Marshall caller before registry commit, duplicate the same request on another node, race cancellation/expiry, and retry with changed user or TERM. Check one live PTY and one durable receipt after settled success, or pending/cancelled with no fabricated success. Do not expose terminal bytes/usernames in diagnostics or SDK metadata. Requery guest after uncertainty, never infer absence from socket loss.

SUT guidance: `Reachable` **"Terminal reconciler recovered guest PTY after lost create reply"** at `Reconciler.recover_opening/2` when `creation_query` reports running; `Reachable` **"Terminal duplicate create returned original session receipt"** at `Creation.complete/2` ready branch. Both are positive search anchors. A real guest instrumentation point can report sanitized PTY IDs without content.

Value menu: same ID 1/2/8 deliveries; two Marshall nodes; drop before guest create, after PTY create, before/after DB complete; user/TERM identical or changed; 63/64/65 active+pending sessions (configured cap 64); request age 599/600/601 seconds. Hosted Marshall/PostgreSQL/host stream plus TCG guest tests PTY identity; native Firecracker/terminal isolation requires native machine execution. Preserve guest and host supervisor lifetimes.

Open questions: What guest-owned birth ledger can count PTY creations that exit between inventory samples? `(partial: creation_status retains one request-to-session identity and LIST shows live sessions, but neither is a cumulative birth counter)` Does the future TCG harness carry the production terminal protocol and real host stream? `(partial: source defines the path, but no composed harness exists)`

### Investigation Log

#### Can guest effects be counted independently?

- Examined: Marshall `Creation` and `Reconciler.recover_opening` query. Found: `creation_query` reports running/exited by request ID and guest_session_id. Not found: a durable guest counter of all past PTY births. Conclusion: check current live identity plus a guest-side observed creation ledger; a PTY born and exited between samples needs explicit guest instrumentation.

#### Does hosted TCG use the real stream?

- Examined: [SUT environment analysis](../sut-analysis.md#antithesis-environments-and-independent-oracles). Found: TCG guest/terminal services are a proposed real mechanism, separate from hosted BEAM services. Not found: assembled focus-specific harness. Conclusion: do not claim guest PTY coverage until composition is recorded.

#### 2026-10-13 follow-up: Which terminald query exposes cumulative creation count?

- Examined: `nix/packages/terminald/src/main.rs:150-188`, `session.rs:137-183,209-299,300-319`, and `lilly/lib/lilly/terminal/vsock.ex:121-134,214-220`.
- Found: `OP_CREATION_STATUS` returns the request's guest session ID and live flag; `OP_LIST` returns current sessions. `create_once` locks the request ledger and returns the same live PTY for a matching duplicate, while conflicting parameters refuse. The registry retains request receipts for at least 24 hours or the session lifetime.
- Not found: a production query for cumulative PTY births, including a PTY created and retired between two LIST calls.
- Conclusion: partial. Add a bounded guest-owned creation-effect ledger or test-only PTY spawn observer for the composed workload; keep it separate from Marshall's Opening/Session rows.

#### 2026-10-13 follow-up: Is the real host stream present in a TCG fixture?

- Examined: `marshall/lib/marshall/terminal/authority.ex:361-399`, `lilly/lib/lilly/terminal/stream.ex:474-510,620-640`, `nix/packages/terminald/src/main.rs:55-112,150-188`, and `../deployment-topology.md`.
- Found: the production route is Marshall authority → authenticated Lilly terminal stream → guest vsock HELLO → terminald `CREATE_ONCE`/`CREATION_STATUS`. A hosted TCG workload must keep all of these links and drop the reply on the real route.
- Not found: an assembled TCG terminal workload or observed reply-loss run.
- Conclusion: partial composition; direct daemon tests establish the registry mechanism only.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest PTY birth/token/deque/process/nonce observed independently of host reply; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/terminal/scenarios.py:96`. Browser LiveView create-reply loss and same-ID duplicate deliveries join SQL opening/session receipt with guest terminald PTY birth and live PID/start; internal guest-create reply loss and hosted physical result remain unverified. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
