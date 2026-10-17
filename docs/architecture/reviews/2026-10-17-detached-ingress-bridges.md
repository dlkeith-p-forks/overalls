# Detached ingress bridges

## Scope and architecture impact

This review covers [ADR-0187](../decisions/0187-detached-ingress-bridges.md),
which amends [ADR-0184](../decisions/0184-lilly-owns-every-socket.md)
decision 3 so a live guest SSH session survives a `lilly-hostd` restart. It
touches:

- the hostd protocol: op 14 `BridgeIngress` (carries Audi's connection),
  op 15 `ListIngressBridges` and op 16 `EndIngressBridge`; hostd options
  `--ingress-peer-user` and `--ingress-slice`;
- `lilly-ingress-bridge`, which gains a `--detached` mode with a READY/GO
  start handshake and no parent-death signal;
- process custody: detached bridges run in transient
  `lilly-ingress-<key>.scope` units in a new `lilly_ingress.slice`, outside
  `lilly-hostd.service`, `lilly.service` and the guest slice;
- Lilly's connector: the BEAM relay leaves the SSH and plain web path; a
  private record per bridge, keepers that own its ingress guardian, and
  re-adoption after a restart;
- the user-SSH journey machine subtest, which now asserts survival and the
  fence instead of the loss.

Domain boundaries, persistence and Marshall are unchanged. The execution
fence keeps its authority source (Lilly's execution view) but gains a bounded
gap while Lilly is down (finding 3).

## Findings

1. **A hostd-only fix could not keep a session.** `lilly.service` has
   `BindsTo=lilly-hostd.service`; systemd propagates a restart of the bound
   unit, so a hostd restart restarts the BEAM. The BEAM relay
   (`Lilly.Ingress.Server.pump/3`) was in the byte path, and the op 13 bridge
   ends with Lilly's socket. Keeping the bridge alive across hostd alone
   (for example with systemd's descriptor store) would still have ended
   every session. Both the relay and the bridge's custody had to leave both
   services.
2. **Descriptor-store re-adoption was rejected on evidence, not taste.** With
   `FDSTORE=1` nothing splices while hostd restarts, hostd would need
   durable per-bridge state to pair descriptors with executions, and finding
   1 still applies.
3. **The fence gap is bounded and explicit.** While Lilly is down no keeper
   runs. A restarted connector ends any bridge without a readable record at
   once, and any recorded bridge whose execution is not current within 30 s.
   A revoked execution's live session can therefore last the downtime plus
   30 s. Lilly cannot change execution authority while down either, and
   Audi's own account-key revocation is unaffected. Recorded in ADR-0187's
   consequences.
4. **Guest bytes must not precede Lilly's ready frame.** sshd speaks first. If
   hostd wrote the ready frame after starting a plain bridge, the guest's
   banner could reach Audi first. The bridge now reports READY, waits for GO,
   and hostd writes the greeting between them; an abandoned bridge exits
   without moving a byte.
5. **hostd must not bridge arbitrary sockets.** The received descriptor is
   accepted only as a connected, non-listening AF_UNIX stream whose peer uid
   is Audi's. Without this a compromised BEAM could hand hostd a connection to
   another local service and bridge a guest to it.
6. **Capacity accounting.** Bridges in `lilly.slice` would have counted
   against the guest memory and CPU limits Lilly reports. A separate slice
   with its own bound avoids that and is never restarted on deployment
   (`X-RestartIfChanged=false`), since restarting it would end every session.
7. **Read-ahead at handoff.** Handing Audi's connection to hostd after the
   BEAM read the request frame would lose any bytes the BEAM buffered.
   [Audi's connector](../../../audi/lib/audi/connector.ex) waits for the ready
   frame before sending stream bytes, so none are buffered.

## Execution record (2026-10-17, uncommitted worktree on `05fd53e47`)

- `lilly-ingress-bridge`: `cargo test` 2 unit (Hegel) and 6 process-fixture
  tests passed, including the new detached handshake fixture; fmt and
  `clippy -D warnings` clean. Not run as root, so the privilege-drop
  fixture returned early.
- `lilly-hostd`: `cargo test` 53 passed, including 7 new ingress tests (Hegel
  models for ops 14 to 16 and scope names, fake-cgroup list and end, the
  client check, the start handshake with a fake helper, the production
  `systemd-run` command line); fmt and `clippy -D warnings` clean.
- Lilly: the new `ingress_bridges_test.exs` (handoff, guardian-death fencing,
  re-adoption, unknown and unadoptable bridges) and the existing connector
  and execution tests passed. `mix precommit`: toolchain, ADR, contracts and
  Dialyzer (0 errors) passed. Two full-suite runs on a host at load 37 on
  32 cores each failed two or three timing-sensitive tests in unrelated
  modules, a different set each time (credentials, transfer stream, vsock,
  execution, channel history). Run together with the ingress tests, those
  files passed (30 of 30), and three repeat runs of the first pair passed.
- NixOS: `overalls` and `dungarees` evaluate; both pass
  `--ingress-peer-user audi --ingress-slice lilly_ingress.slice` and declare
  the slice.
- Machine tests: not run. The coordinator runs `user-ssh-journey-fleet`.

## Machine record (2026-10-17, `user-ssh-journey-fleet`)

`nix build .#checks.x86_64-linux.user-ssh-journey-fleet` passed on the
native host: 16 subtests in 1140.01 seconds, none failed. The subtest "live
guest SSH survives lilly-hostd and Lilly restarts until its bridge is fenced"
passed in 64.99 seconds. Under a live session it saw the same bridge
process in `lilly_ingress.slice/lilly-ingress-<key>.scope`, a new hostd
MainPID, echoed lines after both restarts and past the 30-second grace, and
the adoption event. With the record removed and Lilly restarted, the bridge,
its scope and the session ended while the guest kept its boot. The first
attempt hung before reaching any bridge: the fixture's FIFO holder blocked
on a write-open. The fixture now opens the FIFO read-write after detaching
stdio.

## Production record (2026-10-17, `overalls`)

On the `overalls` host, running a revision that contains ADR-0187, a
temporary VM `bridge-proof` was created through Porsche and reached over
Audi with an ordinary guest SSH session. The bridge was the expected
`lilly-ingress-bridge --detached` process, running as `lilly` in
`0::/lilly_ingress.slice/lilly-ingress-<key>.scope`. A live session printed
a line every 5 seconds for 120 seconds while
`systemctl restart lilly-hostd.service` ran on the host. hostd's MainPID
changed, Lilly restarted with it, and both live bridge processes kept their
PIDs. Lilly logged `lilly.ingress_bridges_adopted` with `adopting` 2 and
`ended` 0. The session printed all 24 lines past the 30-second grace,
reported the same guest boot and exited 0. The VM was then deleted.

## Remaining gaps

- One recorded machine run covers the scope placement, survival across real
  hostd and Lilly restarts, the namespace dial and the adoption grace on that
  test host. The grace on a heavily loaded production host is not measured.
- Editor and nested HTTPS still use op 13 and end on a hostd or Lilly
  restart; their clients reconnect.
- If the connector never runs again, bridges persist until Audi closes them
  or 30 days pass.
