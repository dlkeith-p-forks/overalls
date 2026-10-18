# ADR-0046: Porsche SSH machine management

- ID: ADR-0046
- Date: 2026-09-17
- Status: accepted
- Implementation: implemented
- Components: Porsche, Marshall, Lilly, protocol, NixOS
- Supersedes: none
- Superseded by: none

## Context

The user requested sample-host-style SSH machine management, named the new service
Porsche, and approved the implementation plan. They explicitly require Ash domain
modeling, browser SSH-key management, public HTML and Markdown documentation,
property-based testing and real NixOS machine tests.

## Decision

Porsche is an independent Elixir release beside Marshall. OTP owns connection and
channel processes; Porsche parses bounded commands and calls Marshall over
verified HTTPS using a separate revocable gateway credential. PostgreSQL and Ash
resources in Marshall own keys, approvals, sessions and command receipts. Machine
operations reuse existing Ash actions, transactional admission and Oban/Lilly
execution. Neither SSH disconnection nor diagnostic delivery cancels accepted work.

V1 commands cover help, identity, images, list/show, creation, start/stop/delete,
sharing, key list/removal and request status. Interactive and exec channels share
one parser and command catalog, with human and JSON results. No guest SSH,
console, file transfer, forwarding, OS shell, resizing or relocation is exposed.
Mutations wait for matching physical completion by default (120 seconds), with
explicit timeout and no-wait controls. Acknowledgement alone is not success.

Request IDs persist normalized inputs, resolved resources and results atomically
with domain mutations. Retries cannot change meaning after image defaults change,
VM archival or name reuse. VM UUIDs and globally unique active names are accepted;
names are reusable only after confirmed cleanup and archival. New machines use an
operator-configured default image and browser resource defaults raised to image
minima. Explicit undersized requests fail.

Unknown SSH keys obtain restricted onboarding only after signature verification.
A ten-minute browser approval binds the key to the signed-in account after an
explicit fingerprint confirmation using existing magic-link authentication.
Interactive sessions may continue; exec commands require explicit retry. The
authenticated browser also adds/removes keys directly at /settings/ssh-keys
(the `#ssh-keys` section of `/settings` since [ADR-0196](0196-single-account-settings-page.md)).
One canonical active key belongs to one account. Revocation affects existing
sessions before subsequent commands/polls, without reviving them on re-addition.
Users may remove their final key and retain email login. Every command and poll
rechecks stored authority; usernames and client-supplied ownership are not actors.

Public /docs and page routes serve HTML with Markdown counterparts and an
/llms.txt index. Curated release-packaged content describes public SSH behavior,
not privileged gateway credentials or live account/fleet state. Shared command
definitions and executable examples prevent documentation drift.

Porsche follows ADR-0042: protected JSON/OTP diagnostics, explicit Fluent Bit
classification, bounded metrics and optional encrypted crash dumps. Cloud export
and dumps stay opt-in. Management listens on 22 with a distinct persistent host
key; administrative SSH moves to 2222 before enabling Porsche. Release packaging,
secrets, health, host tooling and update recovery include the new service.

## Alternatives

Embedding SSH in Marshall couples connection faults and deployment. Direct
database/Oban access from Porsche duplicates domain authority. Guest SSH and shell
evaluation expand the scope beyond approved machine management. Separate key
tables or authorization paths for browser registration and onboarding drift.

## Consequences

The gateway is trusted to attest verified key possession, but cannot select
account authority through client fields. New public interfaces need explicit
versioning, bounds and revocation behavior. Port migration requires a working
administrative path. Existing host logging, execution and authorization invariants
remain in force. This adds a fourth independent project verification gate.

## Invariants and verification

- StreamData properties exercise parsing, key identity, ownership, revocation,
  idempotency, name lifetime, reordered outcomes and diagnostic privacy.
- Test account actions against real Ash resources/PostgreSQL with independent
  models and reproducible shrinking. Unit/property checks require no root/KVM.
- Real OpenSSH and browser tests use actual service modules and built releases.
- NixOS fleet checks retain three Marshall nodes, two Lilly nodes and real nested
  Firecracker guests; cover lost replies, restarts and accepted-work recovery.
- Test public docs, source routing, bounded collector failure and actual encrypted
  crash dumps. Explicit flake exports and all project gates are required.
- Missing KVM, live AWS acceptance or unmeasured production capacity cannot be
  represented as passed acceptance.

## Implementation evidence

The [Galileo production review](../reviews/2026-10-02-galileo-production.md)
records repaired integration/team listing objects and the advertised peer flag,
with real API/Porsche-validator properties and deployed acceptance tracked separately.

The [strict local certificate negotiation property](../../../porsche/test/host_certificate_negotiation_property_test.exs)
uses the real default Proof callback and OpenSSH certificate trust. Trusted
matching peers submit one canonical signed-key session; foreign CA, wrong
principal and absent trust fail before backend requests. The pending session is
scripted, so this adds local transport/proof evidence without establishing
Marshall account authority or packaged/native acceptance. The
[property audit](../reviews/2026-09-29-antithesis-property-audit.md) records its
execution scope and remaining boundaries.

The [default-profile histories](../../../marshall/test/marshall/ssh/commands_test.exs)
exercise omitted and explicit profiles through pinned request retries and changed
semantic-input refusals. The [default-profile native journey](../../../nix/verification/tests/machines/default-oss/driver.py)
creates through packaged Porsche and the browser with no profile choice; its
[execution review](../reviews/2026-09-25-default-oss-verification.md) records
passing checks and remaining acceptance gaps separately. This retains the explicit
input identity above; supplying OSS is not the same receipt input as omitting it.
Known Customer sharing rejection now uses the existing forbidden result instead
of a false service-unavailable response, with an
[endpoint regression](../../../marshall/test/marshall_web/ssh_api_test.exs) proving
the 403 and absence of grant, audit, change and SSH receipt effects.

[Shared command validation](../../../protocol/lib/overalls_protocol/ssh_command.ex),
[shared key validation](../../../protocol/lib/overalls_protocol/ssh_key.ex) and
[properties](../../../protocol/test/ssh_key_test.exs) cover bounded canonical keys.
[SSH domain](../../../marshall/lib/marshall/ssh.ex),
[key resource](../../../marshall/lib/marshall/ssh/key.ex) and
[browser page](../../../marshall/lib/marshall_web/live/account_live.ex) (the SSH keys section of `/settings` since [ADR-0196](0196-single-account-settings-page.md)) establish
the first implementation slice. [Domain tests](../../../marshall/test/marshall/ssh/key_test.exs)
and [browser tests](../../../marshall/test/marshall_web/account_live_test.exs)
pass their targeted checks.

[Gateway](../../../marshall/lib/marshall/ssh/gateway.ex),
[session](../../../marshall/lib/marshall/ssh/session.ex) and
[approval](../../../marshall/lib/marshall/ssh/approval.ex) resources now persist
credential generations, expiring sessions and single-use approvals. The
[authority coordinator](../../../marshall/lib/marshall/ssh/authority.ex) checks
current stored authority in transactions; re-registering a revoked key creates a
new identity and cannot revive its previous sessions. Authenticated sessions last
12 hours. Each gateway admits at most 4096 live sessions, including at most 256
pending approvals. The [AshOban retention action](../../../marshall/lib/marshall/ssh/retention.ex)
removes sessions seven days after expiry in bounded batches of 500.

The [session API](../../../marshall/lib/marshall_web/ssh_api.ex) accepts closed,
versioned requests over HTTPS with a dedicated gateway credential. The
[approval page](../../../marshall/lib/marshall_web/live/ssh_approval_live.ex)
uses existing email login and requires explicit fingerprint approval. The
[state model](../../../marshall/test/marshall/ssh/authority_model_test.exs),
[API tests](../../../marshall/test/marshall_web/ssh_api_test.exs) and
[retention test](../../../marshall/test/marshall/ssh/retention_test.exs) exercise
these boundaries against real Ash/PostgreSQL state. The
[review](../reviews/2026-09-17-porsche-ssh-management.md) records verification scope.
The [public documentation catalog](../../../marshall/lib/marshall/documentation.ex)
compiles curated Markdown with Earmark and derives the reference from the shared
command catalog. [Public routes](../../../marshall/lib/marshall_web/controllers/docs_controller.ex)
serve HTML, Markdown and an LLM index without account or fleet queries. The
[documentation tests](../../../marshall/test/marshall_web/controllers/docs_controller_test.exs)
check routes, closed page selection and every command example. The release pages describe the implemented v1 interface for enabled deployments;
actual SSH and lifecycle acceptance is tracked separately below.

The backend tests alone do not establish SSH signature verification. The native
SSH proof checks described below now exercise that separate boundary.

[Machine names](../../../protocol/lib/overalls_protocol/machine_name.ex) have a
shared bounded syntax distinct from UUIDs. The
[VM resource](../../../marshall/lib/marshall/compute/virtual_machine.ex) owns the
name and its active partial unique identity.
[Admission](../../../marshall/lib/marshall/compute/admission.ex) serializes name
claims before placement locks and preserves names across retries and deletion.
The [migration](../../../marshall/priv/repo/migrations/20260917092357_machine_names.exs)
backfills deterministic UUID-derived names and supplies an insert fallback for
older replicas during rollout. Name/UUID resolution uses current domain/Cedar
authorization, and browser views show the name alongside the UUID. The
[name tests](../../../marshall/test/marshall/compute/machine_names_test.exs)
exercise reuse only after confirmed cleanup and preserve archived request identity.
SSH image selection now accepts Marshall's existing immutable SHA-256 digest,
rather than introducing a separate UUID image identity.

[Command receipts](../../../marshall/lib/marshall/ssh/request.ex) and the
[dispatcher](../../../marshall/lib/marshall/ssh/commands.ex) now admit versioned
commands through current session authority and existing Compute/Access/SSH Ash
actions. Receipt creation shares the mutation/job transaction. Replays compare
semantic inputs and return pinned resource identities without re-resolving names,
images or recipients. Commands for one account serialize before authentication-key
locks to avoid cross-key revocation lock cycles; physical waiting occurs outside
these transactions. The first applied terminal
[operation outcome](../../../marshall/lib/marshall/compute/outcomes.ex) is now pinned
for receipt completion. Polling checks current key and VM permissions, including
after archival; acknowledgements do not establish completion. Backend creation
uses configured image defaults and raises omitted sizes to image minima.
[Command tests](../../../marshall/test/marshall/ssh/commands_test.exs) cover these
behaviors with real Ash/PostgreSQL transactions and generated outcome sequences.

The independent [Porsche project](../../../porsche/mix.exs) now contains a
[bounded HTTPS client](../../../porsche/lib/porsche/client.ex). It validates the
closed request envelope, requires HTTPS, verifies certificates and hostnames,
disables redirects and implicit retries, and caps streaming response bytes.
Its [transport tests](../../../porsche/test/client_test.exs) use real TLS with a
local certificate authority, including wrong-CA and wrong-hostname rejection.
The application supervisor now owns proof/session registries and temporary
connection actors. Validated operator configuration starts the listener after
privacy filters and supervision are installed. Successful HTTP
bodies are bounded JSON objects.
The [command runner](../../../porsche/lib/porsche/runner.ex) now allocates mutation
request IDs before submission, validates command receipt envelopes and correlates
polls by request and operation. It submits once and waits outside Marshall's
transactions, with a monotonic deadline and bounded HTTP timeouts. Accepted work
can outlive timeout or transport loss. Its
[state tests](../../../porsche/test/runner_test.exs) exercise generated wait traces;
they do not establish actual SSH or physical guest behavior.

Porsche now configures JSON stderr logging and installs
[source privacy filters](../../../porsche/lib/porsche/privacy.ex) plus OTP report
translation before its supervisor. Structured reports and argument-bearing
diagnostics lose process state and private metadata before handlers run.
[Privacy checks](../../../porsche/test/privacy_test.exs) inspect raw handler events,
including an actual process crash. Fluent Bit now classifies `porsche.service`
explicitly from trusted journal metadata. The
[aggregate metrics process](../../../porsche/lib/porsche/observability.ex) records
bounded counts, durations and errors for completed HTTP and command invocations,
plus BEAM gauges. A strict numeric allowlist rebuilds metric-shaped reports before
handlers see them. [Metric properties](../../../porsche/test/observability_test.exs)
check independent count models, arbitrary metadata exclusion, exception/result
preservation and operation without diagnostic infrastructure. The separate
encrypted service-capture check below now covers actual Porsche crash artifacts.

The [OTP key callback](../../../porsche/lib/porsche/ssh/proof.ex) treats unsigned
probes as candidates only. OTP's successful public-key authentication callback
promotes the same connection process's candidate into a registration whose
lifetime belongs to that process. SSH usernames do not select accounts. The
[connection actor](../../../porsche/lib/porsche/connection.ex) requires that proof
before opening one Marshall session, validates session/approval responses and
observes browser approval. It monitors the SSH connection and closes the session
on disconnect, leaving accepted domain jobs alone.
[Native SSH tests](../../../porsche/test/ssh_proof_test.exs) use OpenSSH for unsigned
probes and valid signatures, plus an OTP client that sends an invalid signature.
They verify that unproven connections never reach the scripted session backend.
Actor checks establish approval transition and disconnect cleanup, but use
scripted HTTP replies rather than a running Marshall instance.

The [listener](../../../porsche/lib/porsche/listener.ex) now configures public-key
authentication, finite connection/channel limits and management-only
[exec/prompt channels](../../../porsche/lib/porsche/ssh/channel.ex). It disables
default shells/evaluation, subsystems and forwarding. Channel workers use the
shared runner and one connection-owned session. Approval can complete within an
interactive connection; unknown-key exec returns instructions without admitting
the requested command. [Input framing](../../../porsche/lib/porsche/ssh/input.ex)
bounds pending bytes across packets. Its incremental CSI/SS3 decoder supports
Unicode grapheme editing and channel-local history (100 entries/64 KiB), with
8192 pending bytes and 64 escape bytes. Recall never submits a command. The
[PTY display](../../../porsche/lib/porsche/ssh/display.ex) wraps/redraws edits and
handles window dimensions while keeping non-PTY output line-oriented. A static
Overalls banner appears only on interactive shell startup. The
[input properties](../../../porsche/test/ssh_input_test.exs),
[display tests](../../../porsche/test/ssh_display_test.exs) and real SSH channel
tests cover fragmentation, history isolation, Enter-only recall, queued input,
EOF, bounds and redraw. Terminal resizing here changes presentation, not VM
resources. See the [prompt review](../reviews/2026-09-18-porsche-interactive-input.md). [Output](../../../porsche/lib/porsche/ssh/output.ex)
separates progress from one exec result and escapes terminal controls.
[Channel tests](../../../porsche/test/ssh_channel_test.exs) use OpenSSH and OTP
clients for real wire behavior, including PTYs, completion waits, channel close,
SFTP/forwarding refusal and cleanup after listener death. Their HTTP backend is
scripted; the separate real-backend tests below cover Marshall-over-HTTPS.

[Runtime configuration](../../../porsche/lib/porsche/config.ex) loads a closed,
bounded JSON file named by `PORSCHE_CONFIG_FILE`. It requires verified HTTPS,
private service-owned credential and host-key files, trusted path custody and
validated optional CA certificates. Invalid configured startup fails closed.
[Configuration tests](../../../porsche/test/config_test.exs) exercise permissions,
symlinks, hardlinks, malformed input and certificate validation.

[Real transport integration](../../../marshall/test/marshall_web/ssh_transport_test.exs)
connects native SSH through Porsche's verified HTTPS client to Marshall's actual
Ash/PostgreSQL actions. Tests cover sharing, revocation on existing connections,
approval on the same connection, lost HTTP replies and idempotent retry without
duplicate VM/job admission. The completion test supplies matching outcome evidence
explicitly; it does not execute a guest. Porsche is a test-only Marshall dependency.

[Nix source packaging](../../../nix/domains/artifacts/default.nix) and the explicit
[payload check](../../../nix/verification/tests/release/probe.exs) now build Porsche with pinned
fixed-output dependencies. Normal and encrypted-runtime releases build. The
payload check executes the packaged runtime and verifies required gateway modules,
shared parsing, invalid configuration rejection and absence of Ash, Oban, Ecto,
other applications and privileged host tools. This does not prove encrypted dump
capture.

The [NixOS module](../../../nix/domains/system/porsche.nix) runs the release as a dedicated
unprivileged user with bounded resources, private runtime credentials and a
persistent management host key. Port 22 requires administrative OpenSSH on 2222.
The [configuration check](../../../nix/verification/tests/evaluation/porsche.nix) rejects port
collisions and missing administrative listeners. The real
[service machine check](../../../nix/verification/tests/machines/porsche-service/default.nix)
passes startup, separate identities/ports, credential custody, restart persistence
and invalid-credential rejection. Marshall and guests are absent from this fixture.
Systemd supplies root/group-readable credentials; startup copies the gateway token
into a service-owned mode-0400 runtime file before strict application validation.
The module wires optional encrypted dumps and retention, but capture acceptance
remains separate.

[Fluent Bit routing](../../../nix/domains/system/logging/normalize.lua) derives the Porsche
source from the journal unit. The [native collector check](../../../nix/verification/tests/evaluation/logging-metrics.py)
passes trusted-source routing and fixed service/environment metric labels with
synthetic summaries. The service machine check now also sends a real SSH attempt,
observes the resulting HTTP failure counter in Porsche's periodic report, and
verifies native Fluent Bit metric output with fixed environment/service labels.
It checks that the gateway credential does not enter collector logs. This is local
service-to-collector evidence, not live AWS export. Destination selection remains
explicit.

[Runtime configuration](../../../marshall/lib/marshall/operations/runtime_config.ex)
and the [Marshall module](../../../nix/domains/system/marshall.nix) accept a canonical
operator default image digest. Browser and SSH omitted sizes use the shared
[Ash image helper](../../../marshall/lib/marshall/compute/image.ex), rounding up
to whole MiB/GiB while preserving explicit inputs and transactional admission.
[Properties](../../../marshall/test/marshall/compute/image_defaults_test.exs) cover
valid minimum bounds; [browser tests](../../../marshall/test/marshall_web/machines_live_test.exs)
prove configured selection and rejection of explicit undersized requests.

[Operator commands](../../../marshall/lib/marshall/operations/ssh_gateway.ex) now
prepare private credentials and configure/rotate/disable gateway authority through
Ash. [Tests](../../../marshall/test/marshall/operations/ssh_gateway_test.exs) verify
file custody, idempotent application and session invalidation. The
[operator guide](../../operations/porsche-operations.md) describes manual release usage.
The private API now includes an Ash gateway readiness action requiring current
gateway authority and a writable, migrated database, without creating a user
session. [Porsche health](../../../porsche/lib/porsche/health.ex) combines that
request with the live SSH daemon check. [The private status server](../../../porsche/lib/porsche/status_server.ex) now
serves fresh versioned readiness over a mode-0600 Unix socket in a private runtime
directory. The updater includes Porsche among required services, secret consumers
and diagnostic preflight checks, and requires its exact affirmative socket reply.
The [encrypted delivery check](../../../nix/verification/tests/machines/porsche-secrets/default.nix)
passes packaged Ash operator issuance/rotation, SSH-derived SecretSpec/SOPS
publication and actual service readiness. It verifies wrong-host rejection,
private credential custody, readiness loss until the replacement is loaded,
unchanged management host identity, and recovery after a missing-value update
preserves the previous bundle while blocking startup. Full fleet acceptance is recorded below.

The [encrypted capture check](../../../nix/verification/tests/machines/porsche-crash-dumps/default.nix)
passes four actual Porsche service crashes and off-host decryption with a disposable
analyst-held RSA private key. It verifies private ciphertext custody, configured
byte/time bounds, count/age retention and fixed metadata-only journal reports.
Weak and missing public keys fail startup; Linux core storage remains disabled.
No live cloud export or full fleet recovery is established by this fixture.

[Host tooling](../../../nix/domains/artifacts/host/cli.py) now selects administrative SSH
ports explicitly for host commands and Nix copies. Approved installation plans
bind source and installer ports; post-kexec calls switch to the installer port.
Marshall enrollment preparation has an independent control-target port. The
[operator guide](../../operations/porsche-operations.md) specifies staged administrative
verification before handing port 22 to Porsche. Existing host-key pinning and
erasure authorization remain in force. The [staged NixOS check](../../../nix/verification/tests/machines/administrative-ssh/default.nix)
verifies real administrative SSH and Nix store access before and after handing
port 22 to Porsche, with the administrative key retained and management identity
separate. It does not perform destructive installation.

The first overalls deployment (`b3c1f2b`) enabled administrative OpenSSH on both
22 and 2222; a fresh pinned connection on 2222 verified login and passwordless sudo.
[Its final configuration](../../../fleet/hosts/overalls/services.nix) assigns port
22 to Porsche and retains administrative SSH on 2222. The
[bootstrap unit](../../../fleet/hosts/overalls/porsche-authority.nix) configures
Ash authority from encrypted systemd credentials before Porsche starts. Reapplying
the declared credential is authoritative, including re-enabling a disabled gateway.
The [deployment review](../reviews/2026-09-18-porsche-overalls.md) records exact
validation scope and remaining acceptance gaps.

The [full fleet check](../../../nix/verification/tests/machines/fleet/default.nix), including
its [Porsche scenario](../../../nix/verification/tests/machines/fleet/scenarios/porsche.py),
passed in 2093.74 seconds against the captured completion revision `5089dea`.
Nine NixOS machines exercise three Marshall nodes, two Lilly nodes and actual
nested Firecracker guests. Acceptance includes browser key approval/removal,
native SSH lifecycle, lost replies and pinned retries, gateway/control-plane
restarts, capacity races, network isolation, release/credential updates, database
outage, daemon death, disk retention/deletion and stale/revoked authority.
The deployment review records the exact driver and scope. This is isolated
multi-machine acceptance on one physical test host, not live cloud acceptance
or a claim about later unrelated platform changes.

The [Overalls live acceptance review](../reviews/2026-09-18-porsche-live-acceptance.md)
records a 50-VM production-host exercise through the
[SSH acceptance runner](../../../scripts/porsche_acceptance.py), including durable
request replay, timeout/disconnect behavior, key revocation and discovered storage
and startup-inventory failures. Sharing was explicitly excluded. Its per-revision
results and scope limits are separate from the earlier isolated fleet acceptance.

The [Teams SSH review](../reviews/2026-09-25-team-ssh-verification.md) covers
permanent Teams refusals and historical receipt authority through the actual
HTTP boundary and packaged Porsche. Closed conflicts use 409, missing references
404 and absent membership 403; malformed create names use 400. Unexpected failures
remain opaque 503. No new wire vocabulary or automatic retries are introduced.

The [host CA review](../reviews/2026-09-25-unified-ssh-host-ca.md) records a
native reconnect between the fixture's readiness check and restart admission.
Porsche preserves Marshall's existing closed `host_unavailable` reason and
shares transport/command conflict classification; it does not retry implicitly.
[HTTPS tests](../../../porsche/test/client_test.exs) and
[runner tests](../../../porsche/test/runner_test.exs) cover that refusal and
single submission. The complete focused Porsche lifecycle passed in the native
`cloning-fleet` check; the generic terminal fixture gap remains explicit in the review.

The [credential retirement review](../reviews/2026-09-25-credential-lifecycle-verification.md)
adds generated histories and committed three-Marshall ordering tests for manual
registration and nested browser approval. Both use the same
[key action](../../../marshall/lib/marshall/ssh/key_actions.ex), which now shares
ADR-0066's account admission fence through the outer commit. Registration cannot
leave an active key after completed retirement cleanup. This is evidence for
database workflow consistency; existing native transport results retain their
original scope and revision.

The [generated invalid startup properties](../../../porsche/test/invalid_boot_property_test.exs)
record local fresh-OTP configuration refusal before named supervision or
reviewed listener/status/observability startup calls. The
[property review](../reviews/2026-09-29-antithesis-property-audit.md) distinguishes
loader baseline acceptance, private fixture custody and base-only unset startup
from configured SSH/host-certificate and native management acceptance.

The [host-certificate boot property](../../../porsche/test/host_certificate_boot_property_test.exs)
adds local first-listener-child refusal with real disposable Ed25519 private keys
and certificates. Invalid signatures, leaf binding, validity, type, options and
principal shape must fail before `ssh.daemon`, status and observability starts.
A real configured loopback daemon supplies readiness and an SSH banner as the
positive trace control. The
[property review](../reviews/2026-09-29-antithesis-property-audit.md) keeps this
startup evidence separate from certificate negotiation/client CA trust,
authorized management, production releases and native deployment acceptance.
The listener contract records its existing guard without changing behavior.

*Transport (2026-10-05).* Porsche's `ready`, `sessions`, `session`, `close`
and `commands` requests now travel as `porsche.*` over the control WebSocket
([ADR-0142](0142-overallsprotocol-control-websocket.md)), bound to the
gateway credential.

- Error names keep their HTTPS classes.
- A dropped socket leaves a request unproven, and the existing request ID
  makes retries exactly-once.
- `host-certificate` stays HTTPS for lyra, and the Inception publication
  probe still calls `ready` over HTTPS.
- The `sessions`, `session`, `close` and `commands` HTTPS routes are deleted;
  the [API tests](../../../marshall/test/marshall_web/ssh_api_test.exs) reach
  them through the shared request module the socket service wraps.

## Open questions

No unresolved product choices. Live cloud acceptance and measured queue capacity
remain deployment-specific evidence. Required Porsche application and machine
checks have passed; subsequent unrelated platform changes retain their own
verification obligations.

## Related decisions

Pending Porsche management calls preserve terminal version refusal after actual
control close4001, rather than masking it as a transient transport error. The
[control review](../reviews/2026-10-05-control-first-envelope.md) records the
original counterexample, generated scripted-TLS regression and guard-reversion
falsification with passing restored execution. This is local transport adapter
evidence; it does not replace native SSH or deployment acceptance. Accepted
rationale and implementation status are unchanged.

[ADR-0002](0002-elixir-ash-and-types.md),
[ADR-0003](0003-control-plane-coordination.md),
[ADR-0008](0008-identity-sharing-and-terminal.md),
[ADR-0010](0010-capacity-admission-transactions.md),
[ADR-0018](0018-persisted-sharing-and-user-machine-access.md),
[ADR-0033](0033-nixos-machine-verification.md),
[ADR-0036](0036-automatic-host-updates.md),
[ADR-0037](0037-workload-placement-and-relocation.md),
[ADR-0042](0042-host-observability.md),
[ADR-0043](0043-declarative-host-provisioning.md).
