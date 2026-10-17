# Porsche SSH management implementation review

## Scope and architecture impact

Implement the user-approved Porsche plan and browser SSH-key management using Ash
domain modeling. [ADR-0046](../decisions/0046-porsche-ssh-management.md) records the
new gateway/API boundary and accepted choices. Existing user changes, including
enrollment and relocation work in this checkout, are outside this review.

Related requirements are ADR-0002/0003 (Ash and coordination), ADR-0008/0018/0022
(identity, access and fresh browser login), ADR-0010 (admission), ADR-0033/0036
(machine acceptance and updates), and ADR-0042/0043 (observability and deployment).
No existing execution, capacity or recovery requirement is superseded.

## Implemented foundation

- [Shared key parser](../../../protocol/lib/overalls_protocol/ssh_key.ex) validates
  bounded Ed25519, ECDSA and RSA public blobs and derives canonical fingerprints.
  It rejects private-key formats, certificates, options and multiple-key input.
- [Command catalog/parser](../../../protocol/lib/overalls_protocol/ssh_command.ex)
  supplies a closed v1 grammar without shell evaluation or peer-created atoms.
- [SSH domain](../../../marshall/lib/marshall/ssh.ex) owns an audited, archived Ash
  key resource. Owner and fingerprint serialization enforce the account limit and
  one active owner. Public operations use the actor, not client ownership.
- [Browser page](../../../marshall/lib/marshall_web/live/ssh_keys_live.ex) uses the
  existing fresh-login hook and authentication diagnostic redaction. Failed input
  is cleared so an accidentally pasted private key is not reflected to the UI.
- [Migration](../../../marshall/priv/repo/migrations/20260917082520_ssh_keys.exs)
  only adds key/history tables and the partial unique fingerprint index. The
  generator's destructive warning refers to the reverse migration's table drops;
  the reviewed forward migration does not alter existing tables.

## Verification evidence

- Pinned Elixir 1.20.4 / OTP 29.0.6 used through `devenv shell`.
- Protocol precommit passed: 56 cases, including 22 properties, compiler,
  contracts, ADR checks and Dialyzer. This includes improper-list/map boundary
  rejection without exceptions.
- Targeted Marshall key/browser/privacy run passed nine cases, including an
  ownership property, forged-account refusal, re-registration identity, revoked
  browser token and private-input diagnostic exclusion.
- ADR structure/link check passed with 46 records. This is not semantic proof.
- Marshall precommit passed: 307 cases (27 properties), including distributed
  checks, six browser-state tests, compiler, contracts, ADR checks and forced
  Dialyzer with its existing documented upstream exclusion.
- Lilly precommit passed: 208 cases (28 properties), compiler, contracts, ADR
  checks and forced Dialyzer. No new consumer runtime dependency was introduced.

## Session authority implementation

- Ash gateway, session and approval resources own purpose-bound credential
  digests, gateway generations, immutable key identity and expiry. Rotation and
  revocation are checked from persisted state on each status request. Only the
  internal system actor may configure a gateway or attest key possession.
- Approval GET preserves the signed-in user's explicit choice; it does not
  register a key. Confirmation uses the same audited key action as settings,
  under the session/approval transaction. Expiry is checked again after possible
  lock waits. Approval is single-use and cannot rebind an existing session.
- The HTTPS session API validates a closed shared-protocol envelope, rejects
  supplied actor fields and oversized bodies, and returns fixed errors.
  Authentication privacy tagging precedes request diagnostics; tests inspect
  debug logs for credential and approval-URL exclusion.
- Session retention uses a real scheduled AshOban action, bounded batches and
  transactional continuation. Keys and command history are outside its deletion
  boundary. The test drains a 501-row fixture and verifies live authority survives.
- Generated state sequences compare real Ash actions with an independent model
  across approval, revocation, re-addition, expiry, closure and gateway rotation.
- Fixed aggregate SSH request metrics join Marshall's existing observability
  path; the collector's finite metric prefix list admits them. Porsche source
  classification and its own runtime diagnostics remain outstanding.

## Session authority verification

- Protocol precommit passed 61 cases (24 properties), including compiler,
  contracts, ADR validation and Dialyzer.
- Marshall precommit passed 328 cases (31 properties), six browser-state tests,
  compiler, contracts, ADR validation and forced Dialyzer with the existing
  narrow upstream exclusion. Two subsequently added API/metric assertions passed
  in a seven-case targeted run.
- The first Lilly gate passed Dialyzer but had two test failures in permit-journal
  and console-fence fixtures, outside the changed SSH boundary. A focused rerun
  passed all 18 cases (two properties). Concurrent ExUnit instances in this shared
  checkout use the same deterministic temporary paths; that is a possible cause,
  not a demonstrated explanation. The full repeat passed 208 cases (28 properties),
  compiler, contracts, ADR checks and forced Dialyzer without exclusions.
- The collector check initially exposed missing explicit platform selection in
  pure Nix evaluation. The check now passes its supplied package platform to
  `eval-config.nix`. An added native-metric assertion was corrected to match the
  actual Fluent Bit metric name and output syntax. The source-built
  `logging-transports` check passed, including native SSH metric export, CloudWatch
  partial-rejection retries, response privacy, native OTLP and collector management.
  This uses isolated local fixtures, not live AWS credentials or delivery.

## Public documentation implementation

The public route pipeline does not load sessions or fetch account state. A closed
catalog selects compile-time Markdown and HTML, never a request-selected file.
Earmark 1.4.49 renders reviewed repository content during compilation; it is not
started as a runtime application. The dependency lock adds only this package.
The HTML page links Markdown alternatives, navigation and `/llms.txt`; the index
links every published Markdown page. Command syntax/options derive from the
shared catalog, and tests parse all fenced command examples. Pages explicitly
mark SSH execution as a preview until runtime acceptance is complete.

The five targeted documentation checks pass, including a property over arbitrary
page selectors. The updated full Marshall suite passes 335 cases (32 properties)
and six browser-state checks. The full gate also passes compiler, contracts, ADR
validation and forced Dialyzer with its existing narrow upstream exclusion.
Production assets and digest files were rebuilt together.
Desktop and 390-pixel mobile visual inspection of the rendered HTML with those
assets found no clipping or horizontal overflow. This was a local static render;
HTTP route behavior is covered separately by the controller tests.
The updated fixed-output dependency hash was derived by fetching the locked
sources and then verified with the normal Nix dependency target. The ADR checker
passes all 46 records; this validates structure and links only.

The release probe now requires the compiled public documentation, its packaged
source, catalog-derived command reference and LLM index without starting services.
The source-built Marshall release and its Nix release probe passed. This verifies
the packaged documentation, actual Cedar NIF, pinned runtime, generated assets and
independent release boundary; it does not start the web server or establish
OpenSSH/NixOS fleet acceptance. The check used the current filesystem source
selection so newly added implementation files were included without staging
unrelated work in this shared checkout.

## Remaining requirements

Application tests establish durable revocation checks, and native tests now
establish the SSH signature/proof boundary and command channel behavior against
scripted HTTP replies. Actual Marshall integration remains open. Operator image-default
configuration, browser size defaults, startup configuration, operator credential setup,
Nix packaging/port migration, Porsche observability and real OpenSSH/NixOS fleet
acceptance remain to be implemented and verified. No production readiness
or live CloudWatch/IAM/KMS acceptance is claimed. Receipt concurrency and reordered
physical-result models now have application checks; full SSH/fleet acceptance is
still separate.

## Machine identity implementation

VM names now belong to the existing Ash resource and its audit history. The
PostgreSQL partial unique index retains claims through logical deletion, and the
existing outcome coordinator releases them only by archival after cleanup.
Admission serializes names before placement locks. Its idempotency check compares
the resolved name as well as the existing immutable request fields. Generated
names and migration backfills use the VM UUID, with a compatibility insert trigger
for older replicas that omit the new column. UUID-shaped names are reserved to
prevent ambiguous references. Authorized resolution rechecks current Cedar access
and does not authorize a later mutation on its own. Browser cards/detail titles
show the machine name while retaining UUIDs.

Code inspection found that the initial SSH parser expected image UUIDs although
Marshall's image identity is a SHA-256 digest. The shared parser and generated
reference now use the existing immutable digest; no new image identity is added.

The targeted 24-case admission/browser/docs run passed, followed by ten checks
including raw old-writer insertion, deferred foreign-key validation, current
sharing revocation, name lifetime and archived retries. Protocol precommit passed
63 cases (25 properties), compiler, contracts, ADR checks and Dialyzer. The Ash
migration/snapshot consistency check passed. The full Marshall suite passed 342
cases (33 properties), including the real three-peer name race, and passed its
compiler, contracts, ADR, six browser-state and forced Dialyzer gates with the
existing narrow upstream exclusion. Lilly's required full repeat passed 209 cases
(28 properties), compiler, contracts, ADR checks and forced Dialyzer.
This does not establish a multi-release NixOS migration rollout or physical guest
cleanup; those remain part of machine acceptance.

After the final title wrapping change, a browser-only rerun overlapped committed
distributed fixtures and failed its assumption of exactly two available VM slots.
The isolated repeat passed all six browser cases. A final four-case name run
(including its property) also verifies that requests created by the legacy writer
can be retried through current admission without changing VM identity. Generated
assets/digests were rebuilt; no additional production dependency was introduced.

## Command admission and receipt implementation

The private `/api/ssh/v1/commands` envelope is closed and versioned. The new Ash
request resource is keyed by account and request ID; commands cannot supply an
actor. Admission rechecks gateway, session and key authority, then delegates to
the existing Compute, Access and SSH actions. The domain mutation, Oban job and
receipt commit together. Failure to insert the receipt rolls back all three.
Retries compare normalized semantic inputs and use pinned results; JSON/wait
options do not change operation identity. A later reuse of a name or changed
default cannot retarget an accepted request. Sharing/key mutations return their
stored result without reapplying the action. Subsequent polls recheck authority.

Account commands serialize before authentication-key locks. This prevents two
connections using different keys from each holding one key while trying to revoke
the other. It limits concurrent admission per account, not background execution;
long waits belong in Porsche outside database transactions. Capacity measurements
remain deployment evidence.

An operation's `completed` status previously did not distinguish applied success
from failure. It now pins the immutable outcome that first completed it. Receipt
completion checks the operation/VM/placement/epoch/generation binding and that
outcome's state. Late or reordered evidence cannot replace the first result.
Deletion additionally requires VM archival after reclamation. A legacy completed
operation with no pinned outcome cannot establish SSH success; rollout must
update Marshall before enabling the gateway. No historical success is guessed.

The migration adds only the request table, its account/request uniqueness and
operation completion reference. Review corrected a generated down-migration
statement that attempted to alter a constraint after dropping it. Deferred
completion references permit transactional fixture cleanup of the operation/outcome
cycle without weakening runtime identity checks.

Creation selects an explicit image digest or Marshall's `default_image_id`
configuration, then raises omitted sizes to image minima and validates execution
limits. Explicit undersized shapes fail. Operator/Nix configuration and browser
default controls remain unimplemented.

The initial targeted 29-case authority/lifecycle/API run passed. The expanded
15-case command/API run passed, including one generated physical-outcome property,
receipt-insert fault injection, revoked membership, self-key removal, lost replies,
name reuse and diagnostic exclusion. The schema/snapshot check passed. Protocol
precommit passed 67 cases (26 properties), including the closed command envelope,
compiler, contracts, ADR checks and Dialyzer. Marshall's full gate passed 354 cases
(34 properties), six browser-state checks, compiler, contracts, ADR checks and
forced Dialyzer with the existing narrow upstream exclusion. Its three-peer check
verified duplicate request admission and simultaneous cross-key revocation without
a lock cycle. Lilly's full gate passed 211 cases (29 properties) and all required
compiler/contracts/ADR/Dialyzer checks. An expanded request-retry/outcome property
subsequently passed in the eight-case command suite.

Final review found that nested Compute actions could emit admission diagnostics
before an enclosing SSH receipt transaction committed. ADR-0042 requires
post-commit outcome logs. Nested Compute calls now leave that diagnostic to the
outer caller, and SSH emits a fixed event only after successful commit, without
raw arguments or user request IDs. Receipt fault injection now checks both the
absence of false admission logs and a successful-commit positive control.
The first verification after this logging change was interrupted by concurrent
relocation schema work: the updated operation resource selected `relocation_id`
before its migration existed. After that migration became available, the repeated
full Marshall gate passed 354 cases (34 properties), six browser-state checks and
forced Dialyzer. The final sharing diagnostic guard and fault-injection positive
control then passed a 19-case command/lifecycle run, warnings-as-errors compilation
and another forced Dialyzer check with the existing upstream exclusion. No new
exclusion was added. The final structural ADR check covers 47 decisions. ADR-0037
and ADR-0042 now link the additional completion-evidence and post-commit logging
behavior; their accepted rationale and implementation statuses remain unchanged.

## Independent Porsche client

The new Porsche Mix project preserves ADR-0046's independent release boundary:
it depends on the shared protocol and HTTP/logging support, without Marshall,
Lilly, Ash, PostgreSQL or Oban runtime dependencies. Ash domain ownership stays
in Marshall. Its supervisor currently has no SSH listener or command workers.

The HTTPS client validates outbound envelopes through the shared schema, requires
a canonical gateway credential and HTTPS origin, verifies the certificate and
hostname, disables redirects and implicit retries, and limits responses while
streaming to 1 MiB. Remote error bodies and exceptions become fixed error atoms.
Successful bodies are JSON objects; session/command interpretation is still
pending and this transport alone does not attest key possession or completion.

Six transport cases (one property and five tests) passed, including actual TLS,
wrong CA/hostname, redirection, remote failure, disconnect, malformed envelope,
oversized body and malformed JSON. The first certificate fixture incorrectly
used a self-signed leaf; a dedicated CA and signed leaf establish the intended
positive and negative controls. An assertion was also corrected to preserve
case-sensitive credential bytes while accepting case-insensitive header names.
The initial full gate reached Dialyzer with zero warnings, but exited nonzero
because those earlier tests failed; that invocation is not a passing gate.
The corrected full Porsche `mix precommit` then passed: pinned runtime, ADR
structure, contracts and their regression tests, warnings-as-errors compilation,
formatting, all six cases and forced Dialyzer with zero warnings or exclusions.

Architecture impact remains within accepted ADR-0046, with unchanged Ash
authority. SSH proof callbacks, response interpretation, physical waits, source
logging protection, service packaging and all real SSH/fleet acceptance remain
outstanding.

## Command waiting and source diagnostics

Porsche's runner now parses the shared grammar and assigns an opaque request ID
before each mutation submission. It reports that ID through a caller-provided
progress callback, never through application logging. Each invocation submits
the original command once. Physical commands poll the authorized `request show`
action using the original session, checking both request and operation identity.
Only an explicit terminal receipt completes the wait; failure and supersession
exit nonzero. A local timeout retains the accepted receipt and does not cancel
work. Read commands and synchronous mutations do not poll. The 120-second default,
explicit timeout and no-wait behavior now exist below the pending SSH channels.

HTTP requests accept only a bounded remaining-time option. Waiting uses a
monotonic deadline; HTTP latency consumes the same budget. A poll ending at the
deadline can report timeout, while an explicit authorization rejection remains
an authorization error. Transport failures retain the request ID for explicit
recovery and never repeat admission automatically.

The application installs OTP translation and a primary logger filter before its
supervisor. Its default formatter writes JSON to stderr with a finite metadata
allowlist. Structured reports and format/argument messages are reduced to fixed
categories at the source; private or SSH-domain string messages are similarly
redacted. This includes state, mailbox/exception data and report callbacks, so
adding another handler cannot recover those fields. A real crashing GenServer
and a raw logger handler exercise this boundary. Fluent Bit routing, metrics and
encrypted dump integration are still pending.

The final Porsche `mix precommit` passed 20 cases (three properties and 17 tests),
the pinned runtime, ADR/contracts checks, compiler, formatting and forced Dialyzer
with zero warnings or exclusions. Generated wait traces establish local runner
state behavior; they do not establish guest completion or real SSH acceptance.
The transport suite also uses real TLS to exercise the new short request budget.
Architecture impact follows accepted ADR-0046 and ADR-0042, with Ash authority
unchanged and both decisions remaining partial.

Before connecting these pieces to SSH, pinned OTP-29.0.6 source was reviewed:
[ssh_auth](https://github.com/erlang/otp/blob/OTP-29.0.6/lib/ssh/src/ssh_auth.erl)
calls `is_auth_key` for unsigned probes and again before verifying a signature.
[ssh_fsm_userauth_server](https://github.com/erlang/otp/blob/OTP-29.0.6/lib/ssh/src/ssh_fsm_userauth_server.erl)
calls `connectfun` only on the authorized path, in the connection process. The
future binding must promote only the candidate belonging to that process after
this success callback; key lookup alone must never open a Marshall session.
Native proof checks now supplement that source evidence as described below.

## Native SSH proof and connection lifetime

Porsche's key callback stores only the latest canonical candidate in the OTP
connection process. It clears candidates on every attempt and never opens a
session during key lookup. The successful public-key callback registers the
proven key under that same process; process death removes the registration.
Telemetry contains fixed event names and counts without key or account labels.

A temporary connection actor requires that registration, monitors the transport
process and opens one Marshall session. It validates canonical session tokens,
session/account identifiers, expiry syntax, the proved key's fingerprint and the
fixed approval path. Pending actors check status for browser approval, discard
the consumed approval path when authenticated and retain session custody for
subsequent commands. Cached authentication is transport state, not authorization:
the runner and Marshall still reauthorize every command and receipt poll. On
disconnect, the actor closes its session without cancelling accepted jobs.

Seven native boundary tests pass. OpenSSH offering only a public key generates
an unsigned candidate but no proof or session API call. OpenSSH with the private
key proves possession despite an unrelated username. A custom OTP client sends
a deliberately invalid Ed25519 signature through the real protocol; it also
cannot produce proof or reach the session API. The suite verifies registration
cleanup, refusal to start an actor without proof, pending-to-authenticated
transition, one session open and closure on disconnect. HTTP replies in these
actor checks are scripted; the suite does not claim real Marshall integration.

The initial full Porsche gate passed 26 cases (three properties), including
compiler/contracts/ADR checks and forced Dialyzer with zero warnings/exclusions.
The additional invalid-signature test then passed in the seven-case native suite.
The final full gate passed 27 cases (three properties and 24 tests), all structural
and compiler checks, and forced Dialyzer with zero warnings or exclusions.
Production daemon configuration and command/prompt channels are still missing.
ADR-0046 remains partial; its accepted Ash ownership and completion requirements
have not changed.

## Management channels and listener

The listener uses the proven-key callback and connection actor, public-key-only
authentication, 4096 connection and eight-channel limits, finite handshake/idle
timeouts and a custom management channel. OS/Erlang shells, subsystems and both
forwarding directions remain disabled. SSH debug callbacks discard peer text.
Privacy is installed before accepting peers. The daemon reference is opaque:
health checks use `ssh:daemon_info`, not PID operations. A separate lifetime
guardian stops the daemon if the listener is killed before its terminate callback
can run; native testing verifies that the old connections close.

Exec emits one result with an exit status and separate stderr progress. Prompt
channels support approval without reconnecting, bounded queued lines, PTY echo,
CRLF, backspace, EOF and exit. Each channel runs one transient command worker;
closing the channel stops that worker without sending a domain cancellation.
The parser and runner remain shared across both modes. JSON results round-trip
the response while escaping terminal control characters, including Unicode C1
and line separators. Human output provides fixed labels and escaped values.

Native tests now cover OpenSSH exec stdout/stderr, one session across multiple
channels, pending-key exec refusal, interactive approval, pipelined commands,
physical-result waits, worker termination on channel close, PTY typing, EOF,
oversized input, listener death, SFTP refusal and explicit forwarding-disabled
responses. These use scripted Marshall replies. They prove wire/channel behavior,
not Ash authorization, real physical completion or deployment readiness.
Input properties cover arbitrary packet splits, including multibyte Unicode;
output properties check JSON round trips and control escaping.

Initial verification found the fixture's missing boolean default and the correct
OTP option name (`idle_time`). Dialyzer then identified inappropriate PID use of
the opaque daemon handle; the documented API now supplies health checks. The
expanded output property initially selected a nonexistent StreamData generator
kind and was corrected to its supported `:utf8` generator. These failed runs are
not passing acceptance. Operator configuration and release startup, verified
Marshall integration, Nix packaging and full SSH/guest fleet checks remain open.
The final Porsche `mix precommit` passed 40 cases (five properties and 35 tests),
the pinned runtime, ADR and contract checks, warnings-as-errors compilation,
formatting and forced Dialyzer with zero warnings or exclusions. Final review
keeps ADR-0046 partial: command transport is now exercised natively, while the
production configuration and full deployment evidence remain incomplete.


## Configured startup and real Marshall transport

The closed runtime JSON configuration now validates HTTPS origins, literal bind
addresses, ports and optional CA certificates. Credentials and host keys require
service ownership, private permissions and single-link regular files; ancestor
custody and symlink checks prevent writable path substitution. Configuration is
public metadata containing private file paths, not inline secrets. An invalid
configured startup fails closed. The supervisor uses rest-for-one ordering so
loss of proof/session infrastructure also restarts the listener.

Six integration tests use native SSH, verified HTTPS and actual Marshall
Ash/PostgreSQL actions. They cover account identity and admission, sharing,
revocation on an existing connection, fresh identity after key re-addition,
approval without reconnecting, gateway disablement and CA rejection. A dropped
HTTP response occurs after domain admission; explicit retry returns the original
receipt with one VM/reservation/operation/job. The test uses SQL sandbox state,
so it does not establish database crash durability. The wait test distinguishes
acknowledgement from an explicitly injected matching completion outcome; physical
guest execution remains a NixOS acceptance obligation. The browser approval action
is real Ash, but this transport test does not drive a browser.

The full Marshall gate passed 382 cases (36 properties, 346 tests), compiler,
contracts, ADR and forced Dialyzer checks (one existing upstream exclusion).
Porsche's full gate passed 46 cases (six properties, 40 tests) and forced Dialyzer
with zero warnings/exclusions after correcting a formatting failure. ADR-0046
remains partial. The Ash domain boundary and production release independence are
unchanged; Porsche is only a test dependency of Marshall.


## Source release packaging

The release builder, source allowlist, bundle validation and explicit flake check
catalog include Porsche. Its dependencies use the measured fixed-output hash and
ordinary compilation remains offline. The existing explicit Lilly-only metadata
branch keeps provisioner tools out of Porsche. The release payload check passed
with the pinned Elixir/OTP runtime, actual packaged modules, shared parser and
fail-closed configuration. It also verifies that Ash, Oban, Ecto and the other
applications are absent. The encrypted-runtime Porsche package builds; this is
not encrypted-dump capture acceptance. Structural ADR and contract checks passed.
ADR-0046 remains partial; service/health/update/observability and full fleet
acceptance are still separate obligations.


## NixOS service and collector routing

The source-built service now runs as the dedicated Porsche user with private
runtime/state directories and only the bind-service capability. Management port
22 requires OpenSSH on 2222, and all listener collisions are rejected. Host-key
generation preserves an existing identity across restarts. Gateway credentials
arrive through systemd credentials and are copied into a service-owned mode-0400
runtime file. This corrects an integration failure found by the real VM test:
systemd's root-owned mode-0440 credential did not satisfy the application's
service-owned private-file invariant. The invariant was retained.

`porsche-configuration` passed its administrative-port and credential-wiring
checks. `porsche-service` passed with the actual module and source-built release:
SSH key scans on both ports, distinct identities, private key/credential modes,
unprivileged service identity, restart persistence and fail-closed invalid-token
startup. The fixture contains no Marshall or guests. Its passing output is
`z2ll8pai9dg6jnr1vcpwkpkh5lgiyki3-vm-test-run-kittens-porsche-service`.
Encrypted runtime packaging and service wrapper/retention wiring are present;
actual encrypted Porsche crash capture has not been tested.

Fluent Bit now recognizes `porsche.service` from trusted journal metadata and
allows explicit destination selection. The local native collector check passed
Porsche and Lilly synthetic metric summaries, trusted origin handling, fixed
service/environment dimensions, local CloudWatch failure handling and OTLP
transport. This is not evidence of live AWS delivery or Porsche's own metric
aggregation. No application payload can choose its service identity.

Architecture impact implements ADR-0046 and ADR-0042 without changing their
accepted boundaries. Operator gateway provisioning, updater/readiness integration,
browser/default-image configuration, application metrics, encrypted capture and
full three-Marshall/two-Lilly guest acceptance remain open.


## Bounded application metrics

Porsche now aggregates completed HTTP calls and management commands into two
fixed storage keys, with bounded counts, durations and errors. It emits minute
summaries and four BEAM gauges. The metrics process follows the listener in the
rest-for-one supervisor so its individual restart cannot restart earlier serving
children. Missing metric storage is tolerated by command instrumentation; results
and exceptions retain their original behavior. No request metadata enters storage.

The source filter rebuilds metric reports from a fixed set of nonnegative bounded
numeric fields and strips all supplied metadata/callbacks. Claiming the event name
`metrics.summary` cannot preserve arbitrary report payloads. Properties compare
aggregation against an independent model and inject arbitrary private values into
metric-shaped reports. Raw-handler tests exercise actual periodic emission.

The full Porsche gate passed 51 cases (eight properties and 43 tests), including
forced Dialyzer with zero warnings/exclusions. All six real SSH-to-Marshall
transport tests also passed with instrumentation. ADR-0042/0046 retain their
existing privacy and domain-authority boundaries. Native service-to-collector
verification is recorded below once complete; live AWS remains separate.


The real collector check exposed a second logger boundary: after source filtering,
OTP translation still replaced the metric report with a fixed diagnostic. Adding
a fixed Elixir domain alone did not bypass translation. The pinned
[Logger translation path](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/logger/lib/logger/utils.ex)
passes every structured report through translators. Porsche's translator now
returns no translation only for the exact closed, sanitized numeric summary;
other reports still receive fixed categories. A formatted-output regression now
passes alongside raw-handler tests. The final full gate passed 52 cases (eight
properties, 44 tests), with zero Dialyzer warnings/exclusions.

### Logging parity finding — medium, resolved

The current [Lilly translator](../../../lilly/lib/lilly/otp_reports.ex) and
[Marshall translator](../../../marshall/lib/marshall/otp_reports.ex) have the same
catch-all behavior. Separate pinned-runtime probes loading each actual module,
installing its translator and emitting the normal numeric summary both produced
`OTP runtime_report (process data redacted)`. This contradicts ADR-0042's aggregate
metric delivery requirement: a synthetic collector fixture does not prove actual
application emission. Follow up with strict metric validation and formatted-output
regressions in both applications, retaining diagnostic privacy. No production
fleet or live cloud claim follows from these isolated logger probes.


### Verified service-to-collector emission

The final `porsche-service` NixOS check passed with the actual source-built release
and Fluent Bit module. An authenticated SSH transport attempt against an absent
Marshall fixture generates one HTTP transport error. Porsche's real minute report
retains that counter, journald carries the structured JSON, and the collector emits
`kittens_gauge_http_errors` with value 1 and only fixed environment/service labels.
The gateway credential is absent from collector logs. Earlier custody, port,
persistence and invalid-credential checks still pass. No synthetic application
summary is injected in this machine check. Marshall/guests and live AWS are absent.

This closes Porsche's application metric-emission gap. The existing Marshall/Lilly
translator defect above remains open, as do updater/readiness integration,
operator gateway provisioning, default-image/browser configuration, encrypted
capture and full fleet acceptance. Structural governance checks passed separately.


### Marshall and Lilly parity correction

Both applications now install a metric-specific primary filter before serving.
It rebuilds summaries using the fixed metric names derived from their observation
catalogs, bounded nonnegative numbers and fixed service/interval fields. Original
metadata and formatter callbacks are removed. The OTP translators permit only
that exact safe report to remain structured; all other reports retain existing
fixed-category translation. No Ash/domain behavior or metric identity changes.

Marshall's focused logger suite passed six cases (one property); Lilly's passed
five (one property). The focused Marshall run explicitly started telemetry and
installed its production translator/filter before running the tests, without
starting the database application. The new source-built `application-metrics`
NixOS test passed with two actual service nodes: Marshall readiness after explicit
migration, Lilly startup, and real periodic summaries through journald and native
Fluent Bit gauges under their fixed service labels. It injects no metric reports
and makes no guest, replicated-control-plane or live AWS claim.

Full gates were attempted, with validation limits recorded rather than hidden.
Marshall's first run passed 403 of 404 cases; its new test needed an explicit
info-level capture because the test environment defaults to warnings. That was
fixed. A subsequent run encountered concurrently changing relocation schema
(`key_retired_at` missing during the run) and a changed landing-page redirect,
ending at 344 of 404. Lilly's full precommit encountered formatting in concurrent
ingress work; running the suite separately passed 218 of 219, with an unrelated
IngressServerTest connector exit. Forced Dialyzer passed for both applications
(zero Lilly exclusions; Marshall's one existing upstream exclusion). These are
not claims that the current whole-worktree gates are green. The focused tests
and actual-service collector check establish this logging correction.


The structural contract check also encountered duplicated native contract IDs in
concurrent relocation-key client work. The preparation response note now has a
unique preparation-specific ID; its obligation text and implementation are
unchanged. This annotation correction has no architecture or runtime impact.


## Operator image defaults and shared admission

ADR-0046 remains accepted and partial. Deployment now exposes the canonical
default image through `services.marshall.defaultImageId` and manual-release
`MARSHALL_DEFAULT_IMAGE_ID`. Invalid configuration fails with a fixed error.
The existing Ash Image resource supplies pure rounded defaults to browser and
SSH callers; persistent domain ownership and transactional admission are unchanged.
Explicit undersized input remains intact and fails Ash admission.

The focused runtime, image property, browser and SSH command suite passed all
28 cases (five properties and 23 tests), using a separate database partition.
The properties cover unaligned minima and valid execution bounds. Browser tests
prove configured-image selection, successful rounded admission and rejection of
explicit undersized drafts. Full project and source-release gates are recorded
below once finished; this does not establish full fleet acceptance.

Module evaluation confirms the configured digest reaches the service launcher.
The full suite passed 410 of 411 cases, including all 40 properties. Its sole
failure was the readiness test: concurrent work added migration
`20260917121547_relocation_cancellation_intent.exs` after this partition was
migrated, so the dynamic required-version check correctly returned HTTP 503.
This is a moving-checkout limitation; the gate is not reported green.

After applying the concurrent migration, all three readiness tests passed.
The full gate's compiler, formatting, ADR/contracts checks, six JavaScript tests
and forced Dialyzer passed (one existing upstream warning exclusion); the earlier
ExUnit failure still makes that full invocation unsuccessful. No authorization,
persistence or Oban boundary changed in this slice.

The source-built Marshall release check also passed, including startup rejection
of an invalid default digest and the existing isolated payload checks. Output:
`/nix/store/8pa3wvp4693bpq75gxmqqf4bxpwxv2nx-marshall-source-release-check`.
This proves packaged configuration evaluation, not a live deployment.


## Gateway operator file workflow

ADR-0046 remains accepted and partial. `Marshall.Operations.SSHGateway` adds
trusted release commands around the existing Ash gateway actions; no new
persistence or authorization path is introduced. Preparation exclusively creates
and syncs a mode-0600 token in a private directory before changing authority.
Configuration reads that file and returns only public metadata. Reapplying the
current enabled credential preserves its generation; rotation and disabling use
existing domain session invalidation. Fixed errors and the operator privacy scope
exclude credential payloads from diagnostics.

The focused PostgreSQL suite passed three cases (one property, two tests), covering
private file custody, malformed inputs, replay, persisted hashes, rotation and
rejection of old sessions. Full project gate results follow below. Automated
secret delivery and real deployment acceptance remain separate gaps.

The full Marshall `mix precommit` passed: 423 cases (41 properties, 382 tests),
six JavaScript cases, pinned runtime, compiler/formatting, ADR/contracts and forced
Dialyzer with one existing upstream exclusion. The test database used its own
partition. This validates the current application boundary, not a deployed gateway.

The source-built release check passed as well, executing private credential
preparation, validation and overwrite refusal in the packaged runtime without
starting application services. Output:
`/nix/store/l2h3b7giws29xfxirysqpxg5chyq5h7g-marshall-source-release-check`.


## Gateway readiness authority and listener check

ADR-0046 remains accepted and partial. A closed private v1 `ready` route accepts
only the version field. Its Ash gateway action authenticates current enabled
gateway authority and requires Marshall's writable, migrated database check.
It creates no session, approval or machine work and returns only `ready: true`.
User actors cannot invoke the privileged gateway action. This is a point-in-time
observation, not authority for future commands. Existing v1 routes are unchanged.

`Porsche.Health` checks the managed SSH daemon before and after a bounded verified
HTTPS request, requires the exact affirmative response, and maps failures to false.
The focused protocol suite passed four cases (one property), the real Ash API
suite passed nine tests, and the native listener/channel suite passed ten tests.
The listener health test uses scripted HTTP responses; it does not prove a deployed
end-to-end health path. Status-socket and updater integration remain incomplete.

Full protocol, Porsche and Marshall gates passed: respectively 81 cases
(30 properties), 53 cases (eight properties), and 427 cases (41 properties).
Their compiler/formatting, contracts/ADR and forced Dialyzer gates passed; Marshall
retains its one existing upstream exclusion. Lilly's required precommit stopped
on formatting in concurrent control/ingress/VM edits. Its separate test run passed
231 of 232 cases, including all 30 properties; `Lilly.IngressExecutionTest` failed
starting the unrelated connector with `:connector_unavailable`. No Lilly code was
changed in this readiness slice. That consumer gate remains unsuccessful.

Lilly forced Dialyzer passed separately with no errors or exclusions.


## Private readiness socket and updater integration

ADRs 0046 and 0036 remain accepted and partial. Optional validated status-socket
configuration adds a supervised server after the SSH listener. NixOS enables it
at `/run/porsche/status.sock`. It requires trusted ancestors and a service-owned
0700 directory, creates a 0600 socket, refuses live sockets and nonsocket entries,
and removes only stale sockets. It accepts no command input; each connection
receives only a fresh version/ready response. Failures return false.

The updater includes Porsche in required service/secret-consumer lists and
encrypted-dump preflight, then requires an exact affirmative versioned response
within both its remaining deadline and an eight-second cap, bounded to 4096 bytes.
The focused Porsche suite passed ten cases (one property), covering custody,
restart, live readiness changes, invalid paths and failure redaction. Five Python
cases passed, including real Unix sockets through the updater's normal health
method. Real service and updater machine checks are recorded below when complete.

Porsche's full gate passed 57 cases (eight properties), compiler/formatting,
contracts/ADR and forced Dialyzer with no exclusions. The native Marshall transport
suite passed seven tests, including the real private socket through verified HTTPS
to Ash: readiness is affirmative before gateway disable and false immediately
afterward, with no user sessions created. This uses PostgreSQL sandbox ownership,
not a deployed fleet. The existing NixOS updater activation/recovery test passed:
`/nix/store/zmiyrsn547ah8b7j1mnzy8kbwry3w1rc-vm-test-run-kittens-auto-update`.
That fixture establishes updater regression behavior, not a deployed Porsche
rotation or full-fleet update.

Marshall's full gate also passed: 428 cases (41 properties), six JavaScript cases,
compiler/formatting, ADR/contracts and forced Dialyzer with its existing upstream
exclusion. The separate status-directory configuration test was tightened so an
unsafe socket directory cannot be masked by host-key directory validation; all
seven configuration cases passed afterward.

The final source-built Porsche NixOS check passed with the updater enabled and
its timer disabled under test control. It verifies the actual deployment manifest
contains Porsche's status path, health unit and secret consumer, observes false
readiness without Marshall, and retains custody, restart, metric-export and
invalid-credential checks. Output:
`/nix/store/6vrf1bm6bhkcah7ka70r2zargz7n1bms-vm-test-run-kittens-porsche-service`.
The fixture's redundant logging import was removed because the current aggregate
module already imports logging. Full fleet and encrypted capture remain open.


## Actual encrypted Porsche service capture

ADRs 0042 and 0046 remain accepted and partial. No production runtime behavior
changed in this slice; the new explicit `porsche-crash-dumps` NixOS check closes
the actual service-capture evidence gap. Its gateway uses the encrypted source
release through the real service module. A separate analyst node generates an
RSA-3072 private key and receives ciphertext only; the gateway receives only the
public key. OTP's documented SIGUSR1 path forces four real captures. Off-host
`crashdump:pem_decrypt/3` succeeds and the plaintext contains the Porsche listener
module. The private key and plaintext never enter the gateway or test exports.

All four ciphertexts were approximately 5.99 MB with ENC0 headers, private
service-owned mode-0600 single-link custody, and fixed artifact/bytes/encrypted
journal metadata. The running process environment confirms a 256-MiB maximum and
ten-second dump budget; this fixture does not exercise truncation at that limit.
Four captures retain three dumps; aging one eight days and running the retention
service removes it. RSA-2048 and missing public keys fail startup without new
dumps. No plaintext Linux core artifact is created.

The machine check passed:
`/nix/store/i19a89shkflfpg9swis98ypy4v19bhpv-vm-test-run-kittens-porsche-crash-dumps`.
Python compilation and code-contract structural checks passed. This is local
service/analyst evidence, not live CloudWatch export, a fleet failure test, or proof
of measured overload behavior. OTP reference: https://www.erlang.org/doc/apps/erts/erl_cmd.html
and https://www.erlang.org/docs/29/apps/tools/crashdump.html.


## Administrative host transport ports

ADRs 0043, 0045 and 0046 remain accepted and partial. Host SSH and Nix copy
transport now use explicit validated administrative ports with the existing
pinned keys and disabled user SSH config. Source and installer ports are part of
the approved installation plan; legacy plans retain their implicit port 22.
Post-kexec validation, formatting, identity capture and reboot use copied installer
arguments so the source target selection cannot leak across phases. The pinned
nixos-anywhere source was inspected: its documented pre/post-kexec flags are used,
including its internal reconnect. Marshall enrollment preparation selects its own
port without changing host arguments. No fallback port or weaker authentication
was introduced.

Seventeen planning tests passed, including rejection of changed ports before
contacting the target and phase-specific selection. Nine real encrypted enrollment
preparation tests passed with distinct host/Marshall ports:
`/nix/store/2ih1gr6z6y2ich1hzj4cmd9s4rfis89c-kittens-enrollment-preparation`.
Python compilation and contract structural checks passed. The initial real
OpenSSH/Nix store transport check passed; the extended staged Porsche handoff
check is recorded below when finished. This does not establish destructive
installation or full fleet acceptance.

The extended `administrative-ssh` NixOS check passed:
`/nix/store/nmbgfmlrnjignyxsfagjpr9yjfj9083x-vm-test-run-kittens-administrative-ssh`.
It first authenticates pinned administrative SSH and Nix store transport on 2222,
then activates a specialization handing port 22 to the actual Porsche release.
Administrative connections still succeed on 2222/2223, the administrative host
key is unchanged, and Porsche has a distinct management identity. The fixture
waits for initial `multi-user.target` before activation; an earlier run switched
before boot completed and did not start the new wanted service. This is a staged
port-handoff test, not physical installation or automated gateway secret delivery.


## Encrypted gateway delivery composition

ADRs 0046 and 0042 retain their existing decisions. The operator guide now gives
an explicit Porsche SecretSpec/SOPS bundle composition using a raw selected
`PORSCHE_GATEWAY_TOKEN`, root publication and systemd delivery to the service-owned
runtime file. This uses the existing resolver and Ash operator actions; no second
credential authority or secret store is introduced.

The new explicit `porsche-secrets` machine fixture runs real Marshall/PostgreSQL
and Porsche on the same control host. It prepares and rotates credentials through
the packaged Ash operator, seals the actual token for the SSH-derived recipient,
and checks false readiness between authority rotation and service reload. It
also exercises wrong-host rejection and missing-value publication preserving the
old bundle while fencing startup. This fixture does not establish full fleet or
guest lifecycle acceptance.

The first run prepared the private token but failed gateway configuration:
systemd's `EnvironmentFile` overrode the transient service's TLS environment
setting with the role fixture's loopback mode. PostgreSQL correctly rejected
the unencrypted connection. The fixture now selects verified TLS in the executed
command after environment-file loading, matching the production module's ordering.

The corrected source-built machine check passed all scenarios in 94 seconds:
`caihddyc5dvc26ygqigrf9df5apmjrz4-vm-test-run-kittens-porsche-secrets`.
Both initial and rotated runtime tokens matched the private prepared files;
the service could read neither the root bundle nor administrative private key.
The wrong host failed decryption without publication. A missing secret retained
the previous bundle, prevented Porsche startup, and recovered after resealing.
The SSH management identity survived rotation and journal checks found neither
prepared token. No application or secret-resolver behavior changed in this slice;
ADRs 0042 and 0046 retain their accepted decisions and partial platform status.

## Full fleet Porsche variant in progress

The explicit `porsche-fleet` check reuses the existing three-Marshall/two-Lilly
fleet topology and all of its physical guest, storage, network, browser and
recovery scenarios. An optional fixture module runs the source-built Porsche
service beside m1, with separately pinned management identity and administrative
SSH on 2222. The new scenario prepares gateway authority through the packaged Ash
operator, registers owner/member keys through the real browser UI, and exercises
native SSH creation, semantic retry, sharing/revocation, stop/start and deletion.
Guest assertions inspect actual Firecracker process identity and ZFS datasets;
no completion outcomes or capacity are injected. Browser removal also exercises
unknown-key rejection without exposing its private approval response.

This extends verification under ADRs 0033 and 0046 without changing production
boundaries. Python syntax checks pass; the initial source build has been launched.
No fleet acceptance is claimed yet. SSH-specific lost-reply and accepted-work
recovery scenarios remain to be added and verified, beyond the existing fleet
recovery scenarios. The ordinary `fleet` variant retains its original scenarios;
the browser CA initialization now reuses an existing fixture trust database.

The fleet scenario now starts creation through a background native SSH client,
waits for the durable accepted receipt, kills the actual Porsche service, and
requires that the client failed without a final stdout result. It restarts m1's
Marshall service and retries with the same request ID, checking both original VM
and operation identities before native guest/storage assertions. This is a lost
SSH completion result, distinct from the committed-HTTPS-response loss exercised
by the existing transport integration test. The initial evaluated Nix test script
includes this case; execution evidence remains pending.

A subsequent fixture review found that manually starting Porsche with an empty
boot target would omit it after the existing whole-host crash/restart scenario.
The fixture now preserves the production boot target and gates initial startup
on a private credential file prepared after schema migration. The browser recovery
coordinator checks Porsche's unit and listener after host restoration. These later
fixture edits were made after the initial Nix evaluation and require a subsequent
run; the active build cannot establish their acceptance.

The first build completed source releases and test-driver lint/type checks but
could not schedule the VM test: the local builder did not advertise the required
`nested-kvm` feature. `/dev/kvm` exists and the host's KVM AMD nested parameter is
`1`. The already-built derivation is now being run with `nested-kvm` explicitly
listed for this invocation; no guest execution requirement or fallback was removed.

The current source also adds real browser approval on an OpenSSH control
connection: an unknown signed key receives a private approval response without
admitting its requested VM, the signed-in user confirms the generated key's
fingerprint, and the same SSH connection must resolve to that user's identity.
This additional case and boot-gating fixes require the subsequent source run;
they are not contained in the already-built initial derivation.

The daemon did not honor the client's feature override. A privileged local-store
build with explicit verified features started the actual test. It then failed
before boot because the shared fleet bootstrap expected `primary.qcow2` and
`secondary.qcow2`; the current declarative host image builder outputs
`system0.qcow2` and `system1.qcow2`. The bootstrap now maps those actual base images
to its unchanged per-host primary/secondary overlays. This is fixture drift, not
a storage backend change. The revised source build includes this correction,
browser approval and production boot-target preservation. Acceptance is pending.

The public quickstart now explicitly requires keeping an interactive SSH
connection open during browser approval. The authority coordinator requires a live
session; a one-shot exec connection can close before the user opens its link.
The documented alternatives are registering the key in Marshall first or using
interactive approval before retrying. This preserves ADR-0046's session-bound
approval decision. The focused documentation suite passes five cases (one property,
four tests); no deployment status is promoted by this wording correction.

Marshall's full `mix precommit` passed on the updated quickstart/current checkout:
440 ExUnit cases (43 properties and 397 tests), the JavaScript checks, runtime,
compiler, contract/ADR gates and forced Dialyzer. Dialyzer reported one existing
configured exclusion and no new errors. The run used an isolated test database
partition. This is application-gate evidence, not the still-running fleet result.

The remaining ordinary project gates now also pass on the current checkout:
protocol 85 cases (30 properties/55 tests), Porsche 57 (8/49), and Lilly 241
(30/211). All three `mix precommit` processes exited successfully and Dialyzer
reported zero errors. Together with the Marshall gate above, these satisfy the
current application-level checks; they do not replace the physical fleet test,
which is now booting after the disk-image mapping correction.

The environment reboot interrupted the revised fleet run during startup. Host
process inspection confirmed a fresh boot and no surviving test VMs; the cached
derivation was restarted. The reboot also reset `/dev/kvm` to root:kvm 0660,
excluding Nix's dedicated build accounts. After explicit approval, a temporary
`nixbld` group read/write ACL was added using the Nix-provided ACL utility. It must
be removed after the test. Image preparation had already selected TCG before the
ACL was applied; the actual fleet nodes still require KVM with no TCG fallback.
This interruption supplies no acceptance result.

The sandbox created before the ACL change still failed the mandatory KVM access
check before launching a fleet node. A fresh invocation after the ACL was applied
now boots Lilly with `forceAccel` enabled. The prior permission-failure log is
retained separately; software emulation is not being counted as fleet execution.
The temporary host ACL remains cleanup work after the active run.

The fresh KVM run then failed its expected ZFS identity check. Rebuilding the
missing disk-image output after reboot generated pool/dataset GUIDs different from
those embedded in the cached test derivation. The new image metadata reports
pool `13221162097182368518` and dataset `1056318181994237105`; cached service scripts
contain earlier observed identities. The test must be reevaluated against the
rebuilt images. The identity fence remains intact; it is not removed or bypassed.

Source inspection also found the installation fixture's 512 MiB dataset quota
carried into a workload fixture configured for 2 GiB guest disks and an 8 GiB
logical pool budget. Fleet storage startup now sets the real dataset quota to
8 GiB before mounting it. Lilly still reports native free space and all admission
checks remain enabled; no capacity is injected. This correction needs inclusion
in the next evaluated test if the active evaluation already captured its module.

Inspection of the active derivation confirmed its GUIDs were current but its
storage startup script predated the quota correction. A corrected driver build
was started without executing a second fleet. The older Nix process then aborted
with its own `Worker::run` assertion (`!awake.empty()`) after Marshall finished
building; it produced no fleet result. The corrected driver build remains the
path forward. No application assertion or physical acceptance is inferred from
this build-tool crash.

The corrected source-built driver completed and passed NixOS driver lint/type
checks: `bjhkm4xk65l0j2qxaqc0gd5mlqsk44bm-nixos-test-driver-kittens-porsche-fleet`.
Inspection of its captured storage script confirms both rebuilt GUIDs and the
8 GiB quota. The exact packaged driver is now running directly with its captured
configuration in `/tmp/porsche-fleet-final-runtime`, using mandatory KVM and the
unchanged full scenario set. The first invocation needed its output directory
created before startup; the subsequent invocation booted Lilly. This is not yet
a runtime pass, and the temporary host KVM ACL still requires cleanup.

The corrected full driver passed storage startup, schema migration, all three
Marshall readiness checks, and real Lilly enrollment/fresh-capacity observations.
It then failed before key registration, during owner browser sign-in. Safe stage
and bounded route-category/status diagnostics showed a magic-link GET 200,
authentication redirect 302, and sign-in page 200. The fleet operator still seeded
`example.test` accounts, whereas current production validation requires exactly
the organizational domain. Fixture identities now satisfy that policy; no authentication
validation is bypassed. A native contract records this requirement.

Using retained fixture VMs, the updated operator created disposable permitted
identities and issued normal tokens to private files. The updated browser probe
then passed owner/member sign-in and real SSH-key addition in 9.83 seconds.
Diagnostics retain only fixed stages, exception classes, and at most twelve
route categories/status codes; token URLs and page contents are excluded. This
focused reproduction confirms the fixture fix, not the remaining full fleet run.
ADR and contract checks pass. The retained debug driver and temporary KVM ACL
still need cleanup after subsequent verification.

Further retained-fixture work exposed two SSH probe hazards before approval could
be verified: Porsche's module defaults `openFirewall` to false, and the fixture
had not explicitly enabled remote management access; a background OpenSSH control
master can also retain the test driver's captured stdout pipe. The fixture now
opens the configured management port, uses a ten-second SSH connection timeout,
and redirects control-master output to `/dev/null` with a bounded startup wait.
The operator guide documents the explicit firewall option. No production default
or authentication requirement changed. The retained debug driver was interrupted
and closed, cleaning up its VMs; no SSH approval pass is claimed. An updated driver
build is running, and the later control-master pipe correction still needs capture
in the final driver. The temporary KVM ACL remains pending cleanup.

The final driver (`z9zh1q49284hm95mjw0754p5imkwzprs`) captured both SSH startup
corrections and passed lint/type checks. Its isolated KVM run passed storage,
schema, readiness, native host inventories and the steady-state capacity cadence
assertions, then failed the first enable action with `host_not_ready`. Production
enable rechecks five-second freshness after operator release startup; the earlier
observation is not authority at that later instant. The fixture now retries only
that transient response for a bounded thirty seconds, preserving production
validation on every attempt and failing other errors immediately. It never
changes report timestamps or freshness limits. This fixture correction preserves
ADR-0046 and existing admission decisions. All run-owned VMs were cleaned up by
the failed driver; full Porsche/fleet acceptance remains pending.

The rebuilt driver (`p1lg9wq0h9d78rvnmiykcv4k30yhpf1m`) passed lint/type checks.
Its next run was interrupted by another host reboot: the process handle was gone,
host uptime had reset, and no driver or QEMU process remained. Its log ends without
a test result, so it supplies no acceptance claim. The same captured driver was
restarted with fresh isolated state in `/tmp/porsche-fleet-reboot`; subsequent
host process inspection confirmed its driver and nine QEMU nodes remained alive
after a tool-session interruption. This run is still pending.

That restarted run passed native enrollment, capacity cadence, enabling both
hosts, browser owner/member key registration, unknown-key non-admission, explicit
fingerprint approval and authenticated commands on the same persistent SSH
connection. Public HTTPS docs probes also passed. It then timed out waiting for
the background creation client's durable receipt. The transient client unit had
exited immediately; its captured systemd manager PATH includes filesystem tools
but not OpenSSH. The probe used bare `ssh`, unlike its absolute Python executable.
It now uses `/run/current-system/sw/bin/ssh` for every invocation, including the
background unit. This fixture-only correction changes no production protocol or
admission semantics. The failed driver cleaned up its nine VMs. Real guest
creation/recovery and the subsequent full fleet scenarios remain unverified.

The absolute-SSH driver (`kjg5dkbg6abr4hnhz4maxxbnj6cf755n`) passed build checks,
then exposed intermittent browser authentication across replicas: authentication
redirected to `/machines`, which redirected to sign-in. A retained-fleet probe
reproduced it repeatedly. Fixed route/status/HTTP-time diagnostics showed a
rejecting response behind the issuer; direct VM clock readings differed by about
a second. Inspection of a privately retained issued cookie showed `nbf` one
second ahead of the rejecting response's timestamp. Joken's installed validator
requires current time at or after `nbf`, with no clock tolerance.
The same issued token subsequently passed normal signature, claims and stored
presence validation in the packaged Marshall release once clocks had advanced.

The fleet fixture now uses isolated Chrony synchronization against its database
node and checks correction below ten milliseconds before authentication work.
No public time server, token backdating, skipped validation or freshness change
is introduced. This test-infrastructure correction preserves ADR-0046 and the
authentication/admission decisions. The synchronized driver is building; its
runtime verification and full fleet acceptance remain outstanding. Retained
diagnostic VMs must be closed before the next clean run.
