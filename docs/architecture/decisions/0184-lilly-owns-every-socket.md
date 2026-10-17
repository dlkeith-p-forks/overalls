# ADR-0184: Lilly owns every socket it uses

- ID: ADR-0184
- Date: 2026-10-17
- Status: accepted
- Implementation: partial
- Components: Lilly, lilly-hostd, lilly-ingress-bridge, NixOS host tools
- Supersedes: none
- Superseded by: none

## Context

[ADR-0182](0182-unprivileged-lilly-beam.md) step 2 had lilly-hostd open
Firecracker API and vsock connections and VM-namespace TCP connections, and
pass each one to the unprivileged BEAM with `SCM_RIGHTS`. Lilly wrapped the
descriptor with `gen_tcp.fdopen/2`.

After the switch to unprivileged Lilly, the `fleet` machine test never
recorded guest trust, and adoption looped on
`physical_identity_unconfirmed`. A step diagnostic showed every VMM
observation passing except `API.running?`. That check started failing about
seven seconds after launch, roughly ten API calls in, and never recovered.

Experiments on the pinned OTP 29.0.6 runtime (with a positive control: a
descriptor the BEAM created itself closes normally) showed the BEAM never
closes a descriptor it did not create:

- `gen_tcp.fdopen/2`, with either the `inet` or the `socket` backend;
- `socket:open/2` on the descriptor, with `dup` true or false;
- `{fd, In, Out}` ports.

After `close`, the descriptor stays in `/proc/<beam>/fd` and the peer never
sees end of stream. So every passed socket leaked. Firecracker's API server
serves a bounded number of connections and stops answering once about ten
are held open. Production hosts leaked one descriptor per readiness, trust,
credentials, terminal, flush, workspace, API and ingress connection.

This answers ADR-0182's open question: OTP can adopt a received descriptor
without a NIF, but it can never release it.

## Decision

Accepted by the user on 2026-10-17. The user chose the hostd bridge over a
close-only NIF, approved the plan, and said "we do not need backwards
compatibility".

1. **The BEAM only holds descriptors it created.** hostd never sends Lilly a
   descriptor. Its replies carry none, and Lilly receives them without a
   control buffer, so the kernel discards any stray rights.
2. **Connect on behalf (`ConnectUnix`, op 12).** Lilly creates an AF_UNIX
   stream socket and sends it with the request. hostd checks it:
   - it is a socket, AF_UNIX, `SOCK_STREAM`, not listening and not
     connected;
   - the path stays within ADR-0182's confinement (`api.sock` or `v.sock`,
     beneath a `--socket-root`, no symbolic link).
   hostd then connects it and replies `Connected`. Lilly wraps it with
   `gen_tcp.fdopen/2`.
3. **Ingress bridge (`BridgeNetnsTcp`, op 13).** hostd dials the guest
   exactly as before: inside the VM namespace, bound to the tap, with the
   mark and the optional source. It then hands the connection, and an end
   connected to Lilly's socket through a private listener (the accepted
   peer's pid must be hostd's own), to `lilly-ingress-bridge`. The helper
   drops to the service uid with no supplementary groups and
   `no_new_privs`, and splices bytes both ways without parsing or logging
   them. Lilly's end of stream ends the bridge. The guest's end of stream
   half-closes Lilly's side. The bridge is a lease-free command of the
   session: Cancel or session close kills it.
4. **Custody.** A minimal process owns Lilly's `:socket`, monitors the
   `gen_tcp` port, and closes the socket only after the port is down. That
   covers an explicit close, the owner's death and `controlling_process`
   transfers. If the port cannot be created, the socket is closed at once.
5. **Deletion.** `OpenUnix` (op 8), `OpenNetnsTcp` (op 9), the
   `Descriptor` reply and Lilly's descriptor stashing are removed. Op numbers
   are not reused.

This replaces ADR-0182 step 2's mechanism, not its confinement policy.

## Alternatives

- **A close-only NIF.** A tiny NIF closes an adopted descriptor after its
  port is down. It is rejected: native code inside the BEAM, a second
  ownership rule for one kind of socket, and the namespace connection still
  starts in hostd.
- **Ambient `CAP_NET_ADMIN`/`CAP_SYS_ADMIN` for ingress.** Rejected for
  ADR-0182's reasons.
- **Bridge through hostd itself.** Guest bytes would pass through the root
  process. The helper keeps them in an unprivileged process.

## Consequences

- No descriptor leaks. Firecracker's connection limit is no longer consumed
  by Lilly.
- Ingress adds one splice hop and one helper process per connection,
  bounded by hostd's in-flight limit. A hostd restart drops live ingress
  connections, as a Lilly restart already did.
  Amended by [ADR-0187](0187-detached-ingress-bridges.md) (2026-10-17): for
  preface-free services (SSH and plain web) hostd now bridges Audi's
  connection itself in a detached scope that survives hostd and Lilly
  restarts, and the BEAM relay leaves that path. Editor and nested HTTPS
  keep this decision's op 13 bridge and its restart behaviour.
  Amended by [ADR-0192](0192-staged-detached-ingress.md) (2026-10-17): the
  editor and nested HTTPS also use detached bridges, with hostd writing
  Lilly's preface and checking Lilly's exact ready frame first; op 13
  remains only as a fallback.
- hostd's received-descriptor surface is one socket per request, validated
  by kind and state before use. Every other descriptor ends the session.
- Lilly's `:socket` and the `gen_tcp` port share one file description.
  Custody never touches the socket except to close it. hostd connects a
  non-blocking description and retries `EAGAIN` until the request deadline,
  without changing its flags.

## Invariants and verification

- hostd accepts a descriptor only with ops 12 and 13, exactly one, and ends
  the session otherwise (`hostd-receives-at-most-one-descriptor`).
- hostd refuses a received descriptor that is not an unconnected,
  non-listening AF_UNIX stream socket (`hostd-received-socket-kind`). It
  keeps no copy (`hostd-handoff-sole-owner`, `hostd-bridge-handoff`).
- Lilly closes each socket exactly once, after its port is down
  (`owned-socket-custody`).
- The bridge moves every byte unchanged, ends with Lilly, and runs
  unprivileged (`bridge-exact-custody`, `bridge-drops-privileges`).
- Lilly's descriptor count stays flat during reconciliation on a host with
  running guests. The fleet machine test checks this (passing run recorded
  2026-10-17 on `df94ad026`), and production hosts are checked after
  deployment.

## Implementation evidence

- hostd:
  - [`protocol.rs`](../../../lilly/native/hostd/src/protocol.rs): ops 12
    and 13, `Connected`, `carries_descriptor`;
  - [`session.rs`](../../../lilly/native/hostd/src/session.rs): receipt and
    the bridge;
  - [`descriptors.rs`](../../../lilly/native/hostd/src/descriptors.rs):
    validation, connect and handoff;
  - [`exec.rs`](../../../lilly/native/hostd/src/exec.rs): `run_handoff`
    places the descriptors at 3 and 4;
  - tests in
    [`descriptor_tests.rs`](../../../lilly/native/hostd/src/descriptor_tests.rs):
    Hegel decoding models, connect-on-behalf, refusals, misplaced
    descriptors, handoff.
- [`lilly-ingress-bridge`](../../../lilly/native/ingress-bridge/src/lib.rs),
  with process fixtures in
  [`tests/bridge.rs`](../../../lilly/native/ingress-bridge/tests/bridge.rs)
  and Hegel properties. It is packaged in
  [host tools](../../../nix/domains/artifacts/hosts/host-tools.nix).
- Lilly:
  - [`Lilly.Host.Sockets`](../../../lilly/lib/lilly/host/sockets.ex) and
    [`Lilly.Host.Hostd`](../../../lilly/lib/lilly/host/hostd.ex);
  - the custody property test
    [`sockets_custody_test.exs`](../../../lilly/test/host/sockets_custody_test.exs).
    It fails when custody does not close the socket.

- Machine run (2026-10-17, local, `df94ad026`): the full `fleet` test
  passed, including "unprivileged Lilly releases every socket it uses"
  (120.62 s) and the terminal subtest over the namespace dial
  ([review](../reviews/2026-10-17-lilly-owns-every-socket.md)). On both
  production hosts after deployment, Lilly's socket count stayed flat (15–16
  and 11).

- Machine run (2026-10-17, local, `b55b4e1ad`): `user-ssh-journey-fleet`
  passed all 15 subtests. Guest SSH reaches the guest through hostd op 13
  and `lilly-ingress-bridge`, which is the unprivileged BEAM's only route.

Remaining: a hostd restart drops live op 13 bridges, which are now only a
fallback; [ADR-0192](0192-staged-detached-ingress.md) moved the editor and
nested HTTPS to detached bridges, with machine evidence pending. For guest SSH, [ADR-0187](0187-detached-ingress-bridges.md) replaces
the loss with detached bridges; its user-SSH journey subtest "live guest SSH
survives lilly-hostd and Lilly restarts until its bridge is fenced" replaces
the subtest that asserted the loss and has no recorded run yet.

## Open questions

None.

## Related decisions

- [ADR-0182](0182-unprivileged-lilly-beam.md): its step 2 mechanism is
  replaced here, and its open question about OTP adoption is answered.
- [ADR-0176](0176-host-concurrency-single-writers-and-effects.md): hostd as
  the only root component.
- [ADR-0183](0183-guest-dataset-streams-in-hostd.md): the unprivileged
  machine-test evidence.
- [ADR-0187](0187-detached-ingress-bridges.md): amends decision 3 so guest
  SSH and plain web bridges are detached and survive hostd and Lilly
  restarts.
- [ADR-0192](0192-staged-detached-ingress.md): extends that to the editor
  and nested HTTPS.
