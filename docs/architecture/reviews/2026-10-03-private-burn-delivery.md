# Private burn notification delivery review

## Scope and impact

Reviewed the optional Alertmanager module, fixed objective-derived routing,
runtime credential custody, Prometheus sender and scrape, and disposable native
TLS fixture. ADR-0139 adds a significant operational dependency and notification
boundary. ADR-0132 provisional targets and ADR-0138 retention remain unchanged.
The user authorized implementation and deployment; no destination is invented.

## Findings and remaining acceptance

Production delivery remains disabled pending an approved HTTPS destination and
runtime secret provisioning reference. External receiver receipt, its handling
and independently monitored central-host failure remain unverified. Upstream
delivery errors may contain URLs, so stdout/stderr are suppressed; loopback
metrics and service status supply local failure evidence. Build-time schema
validation remains enabled alongside startup validation of the completed
configuration and HTTPS destination.

The actual Prometheus/Alertmanager NixOS test contains firing/resolved delivery,
verified TLS and bearer custody, unrelated/mismatched label refusals, receiver503
retry, restart and HTTP startup refusal assertions. The complete native check
initially passed in 97.52 seconds. The isolated-warning native check
passed in 101.31 seconds. Eighty generated routing histories exercised the actual
Alertmanager routing engine in 9.83 seconds, accepting exact roster tuples and
refusing single-label mutations. Existing burn arithmetic properties are unchanged;
the fixture creates synthetic
alerts only in an isolated VM and does not prove production history/compliance.

## Contract review

Reviewed repository, Nix, module and test ancestor contracts. The implementation
keeps runtime secrets outside the Nix store, uses pinned upstream packages,
restricts address families to IPv4/Unix/Netlink and opens no firewall ports.
Production diagnostics must not expose destination or credential bytes.

## Verification

Python fixture formatting and Ruff passed after correcting an invalid regex
escape. The initial native build failed because the Rust fixture lacked its
pinned C linker; the build inputs now include it. Native execution and publication
gates initially remained pending; no failed run is passing evidence.

The initial execution found a test-only route override that serialized Nix
override objects instead of preserving the production configuration, and missing
nginx TLS enablement. Subsequent runs exposed duplicated journal newlines and
the difference between an active unit and a ready HTTP API. Fixtures now preserve
the route tree, bound framing, and await native readiness. The final check includes
the notification failure counter after receiver503 and all recovery assertions.

Repository hooks passed, including Ruff and ty. The evaluated Nix HLDD check
passed. Rust contract syntax and declaration discovery passed; Nix contracts
were reviewed manually because the pinned CLI does not support Nix files.
Marshall full precommit passed with isolated test partition
`_burn_delivery_20261003`: 1,428 checks (227 properties and 1,201 tests), two
excluded, seed789325, in 1,759.6 seconds. Forced test-environment Dialyzer passed
in 44.7 seconds with zero errors, skips or unnecessary skips. This run precedes
the newer SMTP-only test changes on origin/main; merged verification is separate.

The final outage interval stops the disposable Prometheus producer and waits for
the fast warning's resolved receipt before rejecting requests. The slow warning
is then the sole active reviewed warning, so failure and retry evidence belong
to the warning under test. Prometheus is restored after recovery. Production
traffic and rule arithmetic are unchanged.

The final handbook browser check passed in 61.88 seconds. Actual packaged
Marshall/PostgreSQL over verified TLS rendered every section, including the
optional notification diagram, and exercised diagram teardown and revoked
reader refusal. The earlier pre-diagram browser execution passed in 99.02 seconds;
it is separate historical evidence.

The final publication audit ran the upstream schema checker successfully against
the actual forty-route configuration without runtime credential files. The initial
draft incorrectly assumed those files prevented build-time validation; the final
module enables that gate as well as startup validation. The startup contract names
the enforced non-HTTPS refusal precisely; endpoint reachability and external
acceptance are delivery observations, not startup guarantees.
The complete final native check with build-time schema validation enabled passed in 97.55 seconds.

Merged origin/main's SMTP-only test changes from `9b26caa5` without changing their
production behavior or acceptance gaps. Postmerge focused SMTP passed eight
checks (two properties, six tests), seed993967, in 114.1 seconds. Forced
test-environment Dialyzer then passed in 49.15 seconds with zero errors, skips or
unnecessary skips. The full 1,428-check result retains its premerge scope.

The push race additionally merged `ecfb2ba3` committed-mail test histories.
Both added properties passed postmerge in 45.0 seconds, seed63342, using the
same isolated partition. Forced test-environment Dialyzer passed in 55.21 seconds
with zero errors, skips or unnecessary skips. Production application code and
the tested notification module are unchanged by that parent.
