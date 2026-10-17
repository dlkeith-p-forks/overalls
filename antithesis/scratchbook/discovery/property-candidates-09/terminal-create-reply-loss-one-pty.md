# terminal-create-reply-loss-one-pty

P0; high confidence; safety. SDK callsites **missing** per [fresh scan](../../existing-assertions.md). `Always` **"Terminal create replay retains one guest PTY and one opened receipt"**: one immutable request ID can bind at most one guest PTY, Marshall Session, and `opened` audit receipt; duplicate matching create replies return that same registry identity. A conflicting actor/VM/parameter retry must refuse. `Always` checks each settled request history; timeout remains pending/uncertain until guest query resolves it.

Source: `marshall/lib/marshall/terminal/creation.ex:8-79` locks request and VM, hashes user/TERM, reuses ready/pending opening and refuses changed replay; `:96-159` commits Session, opened receipt and ready Opening in one transaction and reuses ready Session on duplicate. `marshall/lib/marshall/terminal/authority.ex:93-131` reserves before sending create and returns pending on ambiguous result. `marshall/lib/marshall/terminal/reconciler.ex:165-178` queries guest by request ID and completes a running PTY. `marshall/lib/marshall/terminal/opening.ex:26-40,98-107` binds immutable metadata without terminal bytes. The guest PTY implementation is needed as the effect witness; DB rows alone cannot prove one PTY.

History/oracle: use a real authenticated terminal client against Marshall, real host stream and a TCG guest terminal daemon. Record attempted IDs, guest PTY identity/process/creation count through guest-owned query, API session IDs and a separate PostgreSQL snapshot of Opening/Session/Event. Drop the guest-create response, kill Marshall caller before registry commit, duplicate the same request on another node, race cancellation/expiry, and retry with changed user or TERM. Check one live PTY and one durable receipt after settled success, or pending/cancelled with no fabricated success. Do not expose terminal bytes/usernames in diagnostics or SDK metadata. Requery guest after uncertainty, never infer absence from socket loss.

SUT guidance: `Reachable` **"Terminal reconciler recovered guest PTY after lost create reply"** at `Reconciler.recover_opening/2` when `creation_query` reports running; `Reachable` **"Terminal duplicate create returned original session receipt"** at `Creation.complete/2` ready branch. Both are positive search anchors. A real guest instrumentation point can report sanitized PTY IDs without content.

Value menu: same ID 1/2/8 deliveries; two Marshall nodes; drop before guest create, after PTY create, before/after DB complete; user/TERM identical or changed; 63/64/65 active+pending sessions (configured cap 64); request age 599/600/601 seconds. Hosted Marshall/PostgreSQL/host stream plus TCG guest tests PTY identity; native Firecracker/terminal isolation requires native machine execution. Preserve guest and host supervisor lifetimes.

Open questions: Which guest terminald query exposes creation count versus only currently live PTYs? Does the TCG harness carry the production terminal protocol and real host stream without a test-only registry shortcut?

### Investigation Log

#### Can guest effects be counted independently?

- Examined: Marshall `Creation` and `Reconciler.recover_opening` query. Found: `creation_query` reports running/exited by request ID and guest_session_id. Not found: a durable guest counter of all past PTY births. Conclusion: check current live identity plus a guest-side observed creation ledger; a PTY born and exited between samples needs explicit guest instrumentation.

#### Does hosted TCG use the real stream?

- Examined: [SUT environment analysis](../../sut-analysis.md#antithesis-environments-and-independent-oracles). Found: TCG guest/terminal services are a proposed real mechanism, separate from hosted BEAM services. Not found: assembled focus-specific harness. Conclusion: do not claim guest PTY coverage until composition is recorded.
