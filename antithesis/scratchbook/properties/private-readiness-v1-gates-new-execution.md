# private-readiness-v1-gates-new-execution

P0; medium-high confidence; safety. Planned `AlwaysOrUnreachable` message: **"Private readiness v1 must match role and host before new guest execution"**. Where private services are enabled, a new guest start may pass the private dependency gate only after exact affirmative v1 Ziggy and Audi-private readiness, including the configured host identity for Ziggy. A malformed, stale, wrong-role, wrong-host or negative response must withhold that new execution; temporary socket loss is an availability failure, not permission to bypass. The optional private-services configuration makes `AlwaysOrUnreachable` appropriate. The [fresh assertion scan](../existing-assertions.md) finds the assertion **missing**.

Source: `lilly/lib/lilly/private/readiness.ex:3-34` requires Ziggy `{version:1, role:"ziggy", ready:true, host_id}` and Audi-private `{version:1, role:"private", ready:true}` over local sockets; `lilly/lib/lilly/vm/executor.ex:263-282,330-347` checks the gate on new start paths. `protocol/lib/overalls_protocol/readiness.ex:19-60` defines a different **guest boot evidence v1**; a private service health document must not be confused with a guest boot receipt. Actual runtime effect ordering, rather than a direct `ready?/1` unit result, is the property.

Workload and independent oracle: run a real Lilly Runtime with private services configured, control Ziggy/Audi status responses, and issue fresh provision/start commands. Observe direct systemd/Firecracker launch marker and Lilly's durable attempt plus service socket response ledger. Vary status independently and verify no new physical guest start when the prerequisite fails; on restored matching readiness, a fresh authorized command can progress. SUT `Reachable` **"Lilly new guest start passed both private v1 readiness checks"** marks a meaningful compatible path.

Value menu: private services on/off; version 0/1/2; correct/wrong role; matching/foreign host; ready true/false/nonboolean; one service unavailable/slow; provision versus start/restart of a stopped unit; old running guest versus new launch. Hosted real service wiring plus scoped executor can establish gating, while the actual Firecracker start and guest trust boundary needs native testing. The gate covers both stopped-unit `start/5` and stopped-unit `restart/5`; adoption of an already-running unit does not create new physical execution.

### Investigation Log

#### Does the gate cover retained-start recovery or only fresh starts?

- Examined: `lilly/lib/lilly/vm/executor.ex:263-282,330-347`, `lilly/lib/lilly/private/readiness.ex:3-34`.
- Found: both stopped-unit `start` and `restart` call `Lilly.Private.Readiness.ready?/1` immediately before `Driver.start` or `Driver.restart`; the running-unit branch adopts an existing VMM.
- Not found: a separate physical launch route in these executor branches that bypasses the gate. This source trace does not establish native execution under a malformed live socket response.
- Conclusion: resolved for the stated executor boundary; catalog scope should explicitly include stopped-unit recovery starts.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: retained QEMU PID/boot challenge/overlay plus independent guest or connector effect; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R2`: The focused command must also emit a distinct `Reachable` at the actual incompatible/corrupt/restart/negative-status danger branch. Optional-path safety can pass without that branch; positive compatible traffic is insufficient. `R4`: Keep exhaustive fixed decoder/version/migration matrices in ordinary tests. In Antithesis, race representative invalid input with a real restart, authority change or valid effect and observe the independent outcome. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
