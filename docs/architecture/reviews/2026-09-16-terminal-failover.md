# Three-node production terminal failover

## Scope and evidence

Extend the existing single-host browser acceptance to three immutable production
Marshall releases, TLS PostgreSQL, HAProxy, the packaged root Lilly service and
a newly provisioned Firecracker guest. The
[harness](../../../nix/tests/README.md) reuses the isolated
[deployment fixture](../../../nix/tests/README.md). Its trusted
[Marshall helper](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/marshall/scripts/deployment_fixture.exs) requires a
matching disposable-database sentinel; its
[Lilly helper](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/lilly/scripts/deployment_fixture.exs) uses the global host
lock and fixture ownership before physical preparation or cleanup.

This remains one physical host. The work preserves existing protocol, authority,
encryption and lifetime decisions. It improves startup validation and supplies
additional execution evidence; no replacement ADR is needed. Affected decisions:
ADR-0015, ADR-0019, ADR-0020, ADR-0021, ADR-0022 and ADR-0027.

## Findings

### Medium: executable capacity accepted an unusable pool path — fixed

The first fixture used `/tmp/lilly-deployment-<uuid>`. Its resulting API socket
exceeded Linux's limit, so the driver's existing guard prevented launch even
though Lilly had reported execution readiness. This was configuration validation
missing under ADR-0015, not a systemd permission or mount-namespace failure.

[Startup configuration](../../../lilly/lib/lilly/control/config.ex) now rejects
v2 pools whose canonical path cannot fit any VM's API socket. The
[jail layout](../../../lilly/lib/lilly/vm/jail.ex) measures bytes, including the
fixed UUID and suffix; the maximum pool path is 31 bytes. V1 capacity-only
configuration is unchanged. The driver retains its defensive launch check.
[Tests](../../../lilly/test/vm/jail_test.exs) cover Unicode paths, the boundary,
the original failure and binding an actual socket at the accepted maximum. The
root helper checks a valid complete configuration and then rejects an overlong
pool on the same real filesystem before service startup.

### Acceptance fixtures must distinguish VMM readiness from guest readiness

The new service successfully launched a fresh guest, but an immediate browser
command arrived during guest boot. The fixture now waits for the image's root
shell prompt before sending input. This changes the test precondition; the
production observed `running` state continues to describe the verified VMM.

The fault interceptor suppresses server replies only once the command's Enter
input is sent. Command text receives its normal receipt first. A second browser
must observe the resulting guest marker, and later input must remain queued.
Markers are split in the typed command so terminal echo cannot satisfy the
guest-execution assertion. Failure diagnostics report locations and booleans,
without guest bytes, login links or credentials.

### Test scheduling under load — fixed

One existing host-lock test exceeded ExUnit's default 100 ms waiting for its
native helper while the release build and KVM fixture were running. The test now
allows one second for that explicit readiness message. Its process-kill ordering
and proof that a live utility retains ownership are unchanged.

## Verification performed

- Production acceptance passed with three separate packaged Marshall services,
  HAProxy 3.4.3, PostgreSQL 18.6, the packaged Lilly service, the pinned NixOS
  Firecracker guest, Playwright 1.63.0 and Chromium 153.0.8010.12. Complete valid
  configuration loads; the overlong equivalent is rejected before startup.
- A fresh guest boots under the production Lilly service. The owner uses the
  load balancer, the viewer node two and the access-management page node three.
  An accepted command is observed by the viewer while all originating-browser
  replies are dropped. The UI remains in control before and after queuing further
  typing, and that typing sends no further input frame. After routing
  excludes node one and its main process is killed, the owner reconnects as a
  reader with a different terminal session ID and must claim control. Guest file counts prove the accepted command
  ran once and queued input did not execute; the VMM PID is unchanged.
- Shared operator handoff, grant revocation and logout propagate to connected
  browsers across nodes. Control-plane delete reaches archival after physical
  cleanup. Fixture cleanup removes VM units, host state, networking and temporary
  deployment services. Generated-secret scans pass.
- Lilly `mix precommit`: 84 cases (19 properties, 65 tests), compiler and Dialyzer
  pass with zero errors/exclusions. One earlier run exposed the readiness-message
  test timeout described above; the complete rerun passes after its correction.
- Marshall `mix precommit`: 218 cases (23 properties, 195 tests), four opt-in host
  cases excluded, plus six browser-state checks. Compiler and Dialyzer pass with
  the existing single upstream typespec exclusion and no unnecessary exclusions.
- Lilly release rebuilt and exported as an immutable Nix runtime closure using
  the pinned Elixir 1.20.4/OTP 29.0.6 environment. Python syntax checks pass.
  The architecture checker validates all 27 decisions and their links.

Decision statuses remain unchanged. ADR-0022 and ADR-0027 gain local deployment
evidence; the earlier terminal/physical ADRs retain `partial` for their broader
acceptance obligations. No release is claimed deployed outside this development
host.

## Remaining obligations

Broader message reordering/delay cases, Lilly restart during terminal input,
interactive latency and database load remain open. Independent KVM hosts,
cross-host isolation, production database HA/failover/restore, real SMTP delivery,
key custody and workload/100-instance acceptance remain required. This local test
does not claim those capabilities have been accepted.
