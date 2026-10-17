# Underclass local monitor socket pin

## Scope and architecture impact

Advance the immutable Underclass source from `a8e51a7` to `8c4cd02` and carry
its NixOS runtime socket wiring into the fleet module. This changes monitor
authorization: local host users gain tokenless read access to a limited snapshot.
ADR-0102 replaces ADR-0081's unqualified admin-token requirement while retaining
its independent pools, private state, loopback listener, Tailscale publication,
and network bearer-token boundaries.

## Findings

Upstream serves only `GET /monitor` on the Unix socket. Its router is separate
from network administration, and `utop --url` still requires an explicit admin
token. The snapshot contains account labels and IDs, quota state, model names,
usage and recent outcomes, so mode `0666` is a real local disclosure boundary.
It does not include credentials, full prompts or cache keys. The fleet module
creates a searchable `/run/underclass` and leaves the credential environment
file and SQLite database private. Its address-family allowlist now includes
`AF_UNIX` and excludes unused IPv6 transport per the module contract.

## Verification

The pinned package build, Underclass configuration and service VM checks,
upstream locked Rust tests, ADR structural checker, and code-contract checker
passed. The VM check verifies unprivileged local
socket access, socket permissions, network admin-token refusal, and normal
service restart and reboot. These checks do not prove host-user membership,
live provider behavior, or tailnet policy on the physical hosts.

Both physical hosts then activated Git revision `882bc34f` and reported a
healthy update. Overalls and Dungarees each ran package `8c4cd02` with an
active daemon. On each host the socket and runtime directory were mode `0666`
and `0755`; a local user fetched the monitor snapshot, the socket returned
404 for an administration route, and the unauthenticated loopback network
monitor route returned 401. No provider account or tailnet ACL was exercised.

## Remaining gaps

ADR-0102 remains partial for provider/tailnet acceptance and encrypted
restore. Measure ledger growth and revisit local monitor readership if the host
user set expands.
