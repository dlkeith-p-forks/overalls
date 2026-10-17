# updater-failed-activation-recovers-live-roles

P1; high confidence in conditional contract; safety with supplementary progress.
Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
`Always(caught incomplete activation attempts restoration independently for each
previously active consumer/socket; no lastHealthy advancement without verification)`;
message **"Updater failed activation attempts every prior live role without claiming unverified health"**.
Abrupt process death does not execute Python finally; do not conflate it with the
caught UpdateError path or claim immediate universal restoration after SIGKILL.

Evidence: `nix/domains/system/auto-update/runtime.py:580-609` (`activate`) snapshots
affected active consumers/sockets; `:622-661` stops sockets before consumers,
prepares secrets before role restoration, restarts sockets last;
`:663-677` independent per-unit finally recovery so one failed start cannot mask
later roles. `:915-936` (`verify`, `record_healthy`) requires two consecutive
bounded health checks before lastHealthy. `:554-568` fixed migration unit can
outlive updater; next attempt must not launch competing migrator. Updater CONTRACTS
and ADR-0027/0050/0070 preserve guest/installation identity, prohibit DB rollback.

History: make a source-built candidate and save actual active role set; fail stop,
switch, secret start, one consumer start or socket start, including canceled stop
jobs and slow surviving migrator. Let catch/finally finish, inspect every role.
Separately kill updater at each handoff and rerun the real entrypoint under its
host flock; audit persisted state/handoff without assuming finally executed.
Keep two existing native guests writing tagged data throughout.

Oracle: actual systemd job/active/socket state and native migrator PID/start-time,
candidate closure/secret descriptor identity, private durable updater status,
independent guest boot/content, PostgreSQL schema version. A failed restoration
is allowed to remain visibly failed; cannot silently advance lastHealthy.
Do not treat declared closure hash or one successful health response as actual
serving health. Credentials/argv never enter oracle reports or diagnostics.

Guidance: `Reachable` **"Updater attempted a later live role after an earlier restoration failed"**
at actual later systemd action. Supplementary `Sometimes`
**"Updater restored all prior live roles after a finite activation fault"**
checks actual roles/sockets and unchanged guest identities after explicitly
restoring service prerequisites. Mark handoff persistence, switch outcome,
per-role restoration and verified health; avoid broad phase-entry assertions.

Values: 1/2/4 roles; first/middle/last restore failure; socket prior active/inactive;
secret unit unchanged/new; two consecutive healthy versus healthy/unhealthy;
configured healthTimeout with checks just-before/equal/after deadline; migration
absent/running/completed. Native NixOS source-built candidate machine campaign
is required for switch/socket/systemd behavior. Hosted command mocks establish
only ordering logic and cannot prove deployment or surviving physical custody.

Open questions: Which source-built native fixture can record every restoration
action and serving effect while updater/migrator processes die independently?

### Investigation Log

#### Does whole-updater death immediately restore the previous role set?

Examined activate finally block, handoff publication, `run:942-1028`,
`main --cleanup:1065-1084` and `default.nix:193,247` ExecStopPost declaration.
The handoff is a secret-descriptor map, not a durable snapshot of active roles.
ExecStopPost removes staging age identity and preserves validated handoff; it
does not start old consumers. Next real `run` stages/preflights/migrates/activates
or verifies the selected candidate as appropriate. Resolved: no immediate role
restoration guarantee after SIGKILL is established by this code, so the primary
invariant is deliberately the caught-failure path. This is a coverage/policy limit,
not a confirmed SUT defect or reason to invent rollback.
