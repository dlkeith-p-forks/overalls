# ADR-0052: Fenced local guest ingress

- ID: ADR-0052
- Date: 2026-09-17
- Status: superseded
- Implementation: partial
- Components: Audi, Lilly ingress, Lilly VM actors, Lilly networking
- Supersedes: ADR-0007
- Superseded by: ADR-0054

## Context

[ADR-0054](0054-inception-development-profile.md) carries forward this decision
and adds the Inception development profile.

The user's Audi implementation request requires SSH and HTTP/HTTPS guest access.
[ADR-0047](0047-audi-ingress-and-authoritative-dns.md) requires replacing
ADR-0007's ingress prohibition before enabling that access. The existing routed
namespace drops all locally originated traffic and unsolicited forwarding.

## Decision

Under that authorization, retain ADR-0007's Customer/Standard/OSS IPv4 pools,
public egress, anti-spoofing, private/protected-address denial, IPv6 denial,
address retention and direct guest isolation. Replace only the ingress prohibition
with connections admitted through Audi and Lilly's restricted local connector.
No public guest route, DNAT, guest-to-guest route or cross-host relay is added.

Audi stays unprivileged. Both ends of its Unix handoff verify OS peer identity.
Marshall's renewable session establishes platform permission. Lilly independently
requires a connected runtime, exact durable VM/placement/epoch/generation and a
physical running outcome observed by this actor incarnation within two seconds.
Restored journals do not establish readiness. A per-stream guardian repeats these
checks. An independent 1500ms request-start timer kills a stalled guardian. Stream
or guardian failure never stops the independently supervised VMM.

Only Lilly creates guest sockets, using OTP's Linux network-namespace option and
binding each socket to the placement's derived TAP. Its address comes from the
validated local command's profile/slot, never a peer-supplied address. An explicit
operator setting enables nftables acceptance of locally originated, privileged-
marked TCP to supported guest ports and their established replies. Unmarked
output and unsolicited forwarding stay denied. SSH uses its dedicated mark and port 22. Web uses a separate privileged mark
and the app port authorized by Marshall (primary port 1–65535; alternate ports
3000–9999). Only the web frontend consumes that service; there is no public
arbitrary-TCP listener. The kernel enforces protocol family, mark and local
placement routing; HTTP parsing and platform access remain Audi responsibilities.

Network claims retain resource ownership. Enabling the operator-owned ingress
policy neither adopts another host's resources nor changes that ownership. The
existing locked setup procedure replaces only owned tables atomically. Ingress
defaults to disabled; `services.lilly.ingress.enable` explicitly enables it with
a matching local Audi gateway and a UID-checked Unix connector.

## Alternatives

General host routes expose a broad guest connection path. Running Audi as root
combines Internet protocol parsing with host privilege. Marshall-only checks
cannot promptly fence local execution changes. Persisted observations alone can
authorize stale state after restart. Shell relays add an unnecessary privileged
byte-processing helper.

## Consequences

Lilly owns local stream resources. Process, observation or control stalls close
streams and can require reconnection. Existing egress isolation remains required;
ingress does not allow guests to initiate host connections. Deployment and real
kernel/Firecracker acceptance must precede production readiness claims.

## Invariants and verification

- Wrong host, VM, placement, epoch or generation cannot open a guest socket.
- Superseded intent, stale observations and actor/runtime failure close streams.
- Suspended guardians cannot revive expired deadlines.
- Only marked, supported-port traffic on the derived TAP succeeds; unmarked,
  wrong-port, guest-to-host and guest-to-guest traffic remain denied.
- Verify actual namespaces and nested Firecracker guests; unit tests cannot
  establish kernel filtering, physical-host isolation or fleet throughput.
- Stopping Audi, its streams or Lilly preserves independent VM lifetime.

## Implementation evidence

[Actor checks](../../../lilly/lib/lilly/vm/actor.ex),
[runtime resolution](../../../lilly/lib/lilly/control/runtime.ex),
[guardian](../../../lilly/lib/lilly/ingress/guardian.ex) and
[backend](../../../lilly/lib/lilly/ingress/backend.ex) implement local fencing.
[Execution tests](../../../lilly/test/ingress_execution_test.exs) exercise real
actors, durable command changes, Unix/TCP sockets and watchdog failure. Their
guest executor is a loopback fixture. The
[namespace socket implementation](../../../lilly/lib/lilly/network/ingress.ex)
and [optional nftables rules](../../../lilly/lib/lilly/network/policy.ex) implement
the marked SSH and web kernel paths. The
[NixOS network check](../../../nix/tests/machines/audi-ingress/default.nix) uses the
actual release with veth echo fixtures. The
[Lilly module](../../../nix/modules/lilly.nix) and
[application](../../../lilly/lib/lilly/application.ex) now wire the restricted
connector behind Runtime supervision, with persistent
[socket custody](../../../lilly/lib/lilly/ingress/socket_custody.ex) for crash
recovery. The Audi fleet test now passes the authored Firecracker isolation
scenarios across two Lilly hosts.
The check passed marked SSH for both fixtures, unprivileged mark denial,
disabled/unmarked/wrong-port denial, guest-to-host/lateral denial and unsolicited
host forwarding denial. It does not establish Firecracker or fleet acceptance.

The [Audi fleet scenario](../../../nix/tests/machines/fleet/scenarios/audi.py) now
includes a real Lilly main-process kill while SSH and HTTP streams are active.
It requires both streams to end without client timeout, unchanged guest process
identity, a new Lilly process and fresh strict-SSH/verified-HTTPS access afterward.
This physical subtest passes in 26.10 seconds on the immutable `1efb7c0`-based
recovery snapshot, followed by the existing SSH-key revocation check. The
[review](../reviews/2026-09-17-audi-ingress.md) identifies the exact run and its
remaining checks. This establishes the tested main-process crash boundary only.

## Open questions

Measure observation and renewal costs under load before claiming the target
fleet scale. Complete the broader actor/runtime crash and storage-failure matrix.

## Related decisions

[ADR-0007](0007-profile-networking.md),
[ADR-0037](0037-workload-placement-and-relocation.md),
[ADR-0047](0047-audi-ingress-and-authoritative-dns.md),
[Audi review](../reviews/2026-09-17-audi-ingress.md).

Interface references: [OTP socket options](https://www.erlang.org/doc/apps/kernel/inet.html),
[nftables reference](https://www.netfilter.org/projects/nftables/manpage.html).


Web connector implementation now accepts a closed `web` service binding, derives
its guest target through the same executor and namespace/TAP checks, and applies
mark `0x41554457`. The existing SSH mark retains port-22-only filtering. The Nix
network fixture now covers web ports 80, 443, 3000 and 9999, disabled web ingress,
and unsupported services while retaining SSH wrong-port and lateral-denial cases.
The expanded network check passes with real namespaces and nftables. Audi’s
HTTP/WebSocket application tests also pass. The separate
[fleet scenario](../../../nix/tests/machines/fleet/scenarios/audi.py) passes with
actual Firecracker guests across two Lilly hosts: guest-to-guest and guest-to-host
connections remain denied, including guest attempts to set privileged marks.
Native SSH and web ingress succeed; revocation and control-plane outage close
live streams while the VMM survives. Gateway restart restores web readiness
without the CA. These are bounded acceptance scenarios, not fleet-load evidence.

[ADR-0093](0093-audi-mediated-guest-ssh.md) supplies the production guest side
of this decision's already fenced port-22 route. The mark, target derivation and
outer authorization contracts are unchanged.
