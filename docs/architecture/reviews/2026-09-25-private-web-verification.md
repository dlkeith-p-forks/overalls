# Private guest browser authority verification

## Scope and architecture assessment

Campaign improvement 021 starts at published `3f679eff7601491e199152a316d9ad59e5c87938`.
ADR-0077 permits current members to read and use team machines. ADR-0047's private
browser, direct web/viewer/operator/manager and five-second request-start lease
requirements carry forward through ADR-0105. The existing Cedar team rule omitted
web use, and its matrix property explicitly expected that narrower behavior.
The correction adds current team membership to web only. It creates no per-machine
grant, management right, domain, resource, lock, protocol or service placement.
Customer profile admission remains outside and before Cedar. Accepted rationale
and ADR implementation status are preserved.

Source/contract review includes the current Cedar policy/schema and entity
construction, Access and Teams mutations, browser-login and stream coordinators,
execution guard, stored login/sign-out, Audi request-start authority/headers,
existing ingress properties and native team-resource/Audi scenarios. Existing
tests already cover public-to-private revocation, state-bound one-use codes,
bearer purpose separation, expiry/closed leases, private owner/stranger browser
HTTP/WebSocket, host cookies, SSH sharing, uploads and outages. Integration
renewals exercise a different private-service flow. None is claimed absent.

## Reproduction and generated histories

Baseline production policy failed the new generated history with seed `305263`
on the first generated primary-app sequence (empty random tail). After adding
team membership and revoking the direct manager grant, the previously approved
code exchange refused despite the remaining current team membership. The
independent direct/team model expects retained use. Baseline log:
`/tmp/verify021-property2.log`. The second binding property already passed.
An earlier fixture attempt lacked the mandatory published gateway host key;
correcting that fixture prerequisite produced the substantive policy failure.

The repaired focused checks passed **18 checks (10 properties, 8 tests)** in
28.1 seconds with seed `779904`; log `/tmp/verify021-property3.log`. This run
includes existing Customer/public/state/purpose and Cedar role/refusal checks.
A later enhancement additionally checks fresh opening with an old browser cookie
after each sharing change; its final execution is recorded below.

The histories invoke real sharing/team/login/endpoint/sign-out actions and compare
their decisions with a separate operation model. Direct roles and team membership
can independently retain access. A code approved before withdrawal rechecks
membership on exchange. App-cookie binding refuses another private port. A
refused renewal is followed by an explicit gateway-style close; only that closed
ticket is asserted permanently unusable after re-addition. Refusal alone is not
claimed to invalidate a still-unexpired durable row. Generation/expiry mutation
and host observations are explicitly synthetic fault setup, not native evidence.

## Native journey and typing

The `private-web` check composes the existing real team-resource journey with
an ordinary browser logging into a private team guest. The owner installs a typed
disposable origin through real guest SSH. It independently counts HTTP accepts,
original streaming/WebSocket accepts, echoes and actual close/reset. Browser
platform cookies must never reach it. The browser retains its initial page,
fetch and WebSocket without retry or manual cancellation.

Before withdrawal, both durable leases must independently advance beyond their
initial five-second deadline while browser and guest data are live. The ordinary
owner removes membership using packaged Porsche. Browser closure, guest closure,
fresh HTTP 403 with unchanged guest counts and absence of live leases must agree.
Re-addition permits a fresh page while the old page's closed counters and old
guest transports remain final. The fixture uses three Marshall machines, two
Lilly machines, PostgreSQL, proxy, client and local origin/CA; all share one physical
KVM host. No production credentials, providers or deployment are involved.

The executed Python browser/Playwright and guest origin artifacts have separate
pinned type checks; browser JavaScript has strict TypeScript checking. The NixOS
framework retains type/lint checks on the complete composed driver. Parsed JSON
is narrowed from `object` to closed counter/account schemas. Failure output uses
closed stage names without tokens, URLs, exception text or guest payloads.

The strict native driver build passed in 339 seconds at captured source tree
`ae4a82425ea8f33fe878b109ef959c878fde74bc`, producing
`/nix/store/3n13g01pj2i8z27q0npqllwa11mp00la-nixos-test-driver-kittens-private-web`.
The captured runtime derivation is
`/nix/store/0cj8fs29rvss40ifvb5x4z5jdg00y4n4-vm-test-run-kittens-private-web.drv`;
its input driver matches that build. Build log: `/tmp/verify021-native-build5.log`.
Earlier build attempts corrected source inclusion and strict Python/JavaScript
typing; none launched native runtime.

The first native execution failed in the inherited team integration journey,
before any private-web stage. Boot, admission, ordinary key/CLI registration,
shared/personal/Customer provisioning and member/refusal stages passed. After
restarting the shared guest, `stop team-customer` returned the expected
`forbidden`, but the global intent inventory changed during its before/after
comparison. The first fixture did not retain changed fields, so the cause of
that particular drift remains unknown. Log: `/tmp/verify021-native-run.log`,
with full JSONL `/home/ghuntley/.local/state/nix/build-logs/1790370476486-2704828-0.jsonl`.
Cleanup completed in 4.14 seconds; the owner session, driver and all nine QEMU
processes were drained and independently confirmed absent.

Source review identified a missing settled-state prerequisite: a running outcome
can precede the host report that releases startup capacity. The initial
provisioning and later withdrawal stages already wait for zero startup compute
holds. The restart stage now observes the same real prerequisite before taking
the refusal inventory. The full-row equality remains unchanged in scope; typed
row snapshots now report only changed table/column names on failure, excluding
row values, identities, command arguments and header contents. This is a fixture
correction; it does not establish the earlier failure's changed field.

The corrected candidate integrates published `d2a4767147fd726d3f353eda4ed2eb563da646ba`,
including ADR-0126's reviewed production database recovery settings. The shared
terminal helper changes do not change private-web browser behavior. Captured tree
`c3d08d598eda8d3db101cb6888ac207d59f625f6` built the strictly typed driver
`/nix/store/9kbbswmk0wkh5rkc6wmavzyxizny9svi-nixos-test-driver-kittens-private-web`
in 315 seconds (`/tmp/verify021-native-build6.log`). The exact composed script
comparison with the first capture contains only the typed full-row inventory
diagnostics and startup-settlement prerequisite. The private-web script and
origin artifact path are byte-identical. This script comparison does not claim
identical release packages: the integrated production recovery defaults changed.

**Corrected private-web passed all nine native stages in 462.02 seconds.**
Runtime derivation:
`/nix/store/38khrig39v15rrvl0hxpfcgsxcq45aw5-vm-test-run-kittens-private-web.drv`.
Output: `/nix/store/kkxbbkrjqs1gffaqsjf26jm0dhsd3wqm-vm-test-run-kittens-private-web`.
Log: `/tmp/verify021-native-run2.log`; full JSONL:
`/home/ghuntley/.local/state/nix/build-logs/1790371502461-3112977-0.jsonl`.

| Native stage | Passing duration |
| --- | --- |
| Fleet boot, ZFS and nested KVM | 59.42 seconds |
| Authenticated capacity and services | 120.67 seconds |
| Ordinary key registration and packaged Porsche | 22.97 seconds |
| Shared, personal and Customer provisioning | 170.17 seconds |
| Member use, management, foreign and Customer refusals | 12.37 seconds |
| Team integration, shared restart and withdrawal/re-addition | 49.89 seconds |
| Team-only browser HTTP/WebSocket admission and both observed renewed leases | 17.44 seconds |
| Original transport closure, fresh HTTP 403 and unchanged guest acceptance count | 5.92 seconds |
| Fresh HTTP recovery and final old browser/guest transport counters | 2.87 seconds |

The test retained ordinary actors and zero direct grants for the private browser
member. Both original transports closed without navigation, cancellation or
retry. Guest EOF/reset counters agreed with browser closure, and rejected fresh
HTTP did not reach the guest. Restoring membership admitted fresh HTTP while
the original transport counters remained final. Cleanup completed in 4.02 seconds;
the owned session was drained with exit zero and the driver, all nine QEMUs and
the owning Nix/shell processes were independently confirmed absent. The failed
first attempt retains its separate evidence and unknown changed fields.

Independent physical-host failures,
production DNS/CA/load, native direct-grant withdrawal, team terminal/agent and
existing SSH-session withdrawal retain their separate acceptance boundaries.

## Final validation and contract review

The final two private-history properties passed in 37.7 seconds, seed `21001`,
after adding old-cookie opening assertions (`/tmp/verify021-focused-final.log`).
The complete Marshall `mix precommit` passed **1,094 checks (113 properties,
981 tests), two excluded**, in 553.5 seconds, seed `900138`, with distributed
tests included. Browser-state/workspace checks passed; forced test-environment
Dialyzer reported **zero errors, zero skips and zero unnecessary skips**
(`/tmp/verify021-precommit.log`). This gate exercised frozen tree
`ae4a82425ea8f33fe878b109ef959c878fde74bc` on base
`3f679eff7601491e199152a316d9ad59e5c87938`, before the corrected `c3d08d59`
native capture and its integrated 30-check run. Later fixture diagnostics and
settled-state gating, plus the
published ADR-0126 integration, retain separate validation below.

The pinned all-file `prek` gate passed catalog logging, HLDD review, Ruff format,
Ruff lint and ty checks (`/tmp/verify021-prek.log`). Before integration, the dedicated
`marshall_testverify021` database had zero users, teams, memberships, direct
grants, ingress endpoints/services, browser credentials and streams after the
complete gate (`/tmp/verify021-database-audit.log`).

On integrated captured tree `c3d08d59`, **30 checks (13 properties, 17 tests)**
passed in 45.8 seconds, seed `21002`, covering both private histories, existing
ingress/refusal and Cedar checks, and the real runtime configuration regression.
Forced test-environment Dialyzer again reported zero errors, skips or unnecessary
skips (`/tmp/verify021-integrated-checks.log`). ADR, contracts, HLDD and generated
options/coverage/views checks passed. All-file `prek` and Nix `hldd` passed on
this capture (`/tmp/verify021-integrated-prek.log`,
`/tmp/verify021-integrated-hldd.log`). The same dedicated authority/ingress tables
remained empty after the focused run (`/tmp/verify021-integrated-database-audit.log`).

Final semantic review found no remaining source/contract mismatch in this scope.
Current team membership is read from PostgreSQL through the existing Access
entity path, with Customer refusal before Cedar. Direct web-only grants retain
their narrower permissions. The native helper preserves all previously captured
tables/VM intent columns, compares exact typed row equality, and exposes only
changed column names on failure. No new domain, protocol, schema, lock, service
placement or architectural decision is introduced. ADR-0077 and inherited
ADR-0047/0105 rationale and partial implementation status remain intact.

Final integration includes published `5af65d3fe47626523707d7aafe2c1993f91e568c`.
Its terminal reply aliases, waiting/recovery rendering and fixture reply helper
retain their [upstream review](2026-09-25-terminal-startup-recovery.md) and native
startup acceptance limit. All Nix test source, private-web artifacts, Cedar policy,
ingress implementation and private-history properties are unchanged from the
passing native capture. The broader release therefore differs only in the
separately reviewed terminal source and documentation; the native result remains
tied to `c3d08d59`. The evaluated final `private-web.config.testScript` matches
the executed `9kbbswmk` driver's `test-script` byte for byte. The combined
private-web/handbook checks passed **46 checks (17 properties, 29 tests)** in
43.1 seconds, seed `21003` (`/tmp/verify021-latest-checks.log`).
Forced test-environment Dialyzer passed with zero errors, skipped findings or
unnecessary skips. The same eight authority/ingress tables remained empty
(`/tmp/verify021-latest-database-audit.log`). Final ADR, contracts, HLDD and
generated-reference/view checks and Nix `hldd` passed on this integration;
the evidence-only receipts retain the captured native scope.
