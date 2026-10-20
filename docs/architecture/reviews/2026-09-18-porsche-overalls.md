# Porsche on overalls

Porsche implementation and required acceptance are complete. The final acceptance
section and requirement audit below supersede intermediate pending statuses in
this chronological deployment record.

## Scope and decisions

User-authorized exposure of `services.porsche`, enablement on overalls and automatic
deployment by pushing main. Implements ADR-0046 under ADR-0048's single-host
exception, preserving ADR-0036 update sequencing, ADR-0042 diagnostic boundaries
and ADR-0043 authenticated host/secret custody. No replacement decision required.
The isolated deployment branch starts from main's `7965b79`, preserving its
ADR-0050 usage-based capacity changes and excluding concurrent Audi/relocation work.

## Implementation review

The [module](../../../nix/domains/system/porsche.nix) gives Porsche a dedicated user,
private systemd credentials, separate persistent SSH identity and bounded resources.
Port collision assertions require administrative SSH on 2222 before enabling the
management listener on 22. The updater includes Porsche and secret-dependent
operator units in deployment ordering and verifies authenticated readiness through
the private status socket, rather than relying only on unit activity.

The [host authority unit](../../../fleet/roles/control-plane/porsche-authority.nix)
uses Marshall's trusted Ash action. It copies the systemd credential into its
private runtime directory at mode 0600 to satisfy the operator file boundary;
no token is placed in argv, source or the Nix store. The committed bundle is SOPS
ciphertext for the authenticated host and recovery recipients. Matching active
authority preserves its generation. Reapplying the declaration after an operator
disable explicitly re-enables it; this behavior is documented in the
[operations guide](../../operations/porsche-operations.md).

## Verification

The staged administrative-port commit `b3c1f2b` was pushed and automatically
deployed. A fresh pinned SSH connection on 2222 verified hostname, passwordless
sudo and active Marshall. Evaluation passed all host assertions and the ADR and
contract structural checks.

The complete candidate overalls system builds successfully, as do the Porsche
configuration and source-release checks. Protocol (74), Lilly (216) and Porsche
(57) tests and their full precommit gates pass, including property tests and
Dialyzer. The ADR checker passes 50 records and the contract structural gate passes.
Marshall's gate and focused NixOS checks remain running. The user explicitly
requested immediate commit, push and activation while these checks continue;
those pending checks are not represented as passed. Live activation/readiness
will be verified against the committed candidate.

## Remaining acceptance

ADR-0046 remains partial. On the original implementation checkout, the Porsche
fleet scenario passed native SSH, browser key approval/removal, real Firecracker
and ZFS lifecycle operations, gateway/control-plane restarts and receipt replay.
That broader run later failed an obsolete storage-failure assertion: it expected
host telemetry to stop when a pool observation failed. The accepted behavior keeps
host telemetry fresh while clearing the unavailable pool observation and its
allocation credit. Main already contained the corrected oracle, which the current
fleet run preserves. The earlier run is not a full fleet pass or evidence for the
exact isolated deployment revision. Browser image-default integration subsequently
passed its application gate; the full fleet audit remains outstanding. Live cloud export/IAM/KMS and throughput have not been established.

## Activation and terminal correction

Revision `9d86721a4b668f154fb7d5c01bca119acd8ece1f` automatically activated and
was recorded healthy by overalls' updater. A fresh pinned administrative connection
on 2222 verified active Porsche, its Ash authority bootstrap and Marshall. Port 22
advertises the Erlang SSH service and uses the separately verified ED25519 key
`SHA256:d4Rhkra+2OSj84CSN8KQpLUIGXafYuGFtIcFsmPQ/ag`.

The user then observed staircase formatting in the real interactive terminal.
The SSH channel emitted bare LF while OpenSSH put the terminal in raw mode.
The channel now converts each PTY output stream to CRLF, preserving existing
CRLF from input echo and leaving non-PTY bytes unchanged. The native SSH PTY
regression checks approval output, command results and echoed CRLF, rejecting
bare LF and doubled carriage returns. This is an ADR-0046 protocol implementation
correction with no change to domain authority or accepted architecture.

The PTY correction (`7d7976b`) was verified against live overalls with a pinned
OpenSSH PTY, fresh synthetic client key and bounded private capture: banner,
approval instructions and prompt contain CRLF without bare LF or doubled CR.
Approval URLs and session material were not emitted in diagnostics.

Continuing verification found the deployment selection omitted the explicit
`:ready` entry in the Ash gateway internal-action allowlist. The prior updater
could record the initial deployment healthy using unit activity, but the newly
installed updater's authenticated Porsche readiness correctly failed closed.
The action is now explicitly admitted only for the existing trusted system actor;
the coordinator still checks current gateway credentials and database readiness.
All 16 SSH API and real HTTPS transport tests pass after the correction, including
gateway revocation and missing-migration rejection. The failed encrypted-secret
machine check used the earlier release and will be rerun against this correction.
Full Marshall validation remains pending; its first local run also exceeded the
local test database connection limit with 64 BEAM schedulers, so the rerun uses
eight schedulers and an isolated test database.

## Readiness verification and completion candidate

The updater subsequently recorded `4ad6006227e3362471862088ee3c09f773ee3a47`
healthy with the authenticated Porsche readiness check enabled. The corrected
`porsche-secrets` machine derivation passed in 89.22 seconds, including rotation,
wrong-host decryption refusal and failed-publication fencing. The earlier focused
updater, Porsche service, administrative SSH and encrypted crash-dump checks also
passed. Marshall's corrected application run passed 404 tests (39 properties and
365 tests); its full gate passed, including forced Dialyzer with the existing repository exclusion.

The next candidate brings the full `porsche-fleet` test into the deployment
checkout, preserving main's newer capacity scenarios and unavailable-pool oracle.
The isolated fixture synchronizes replica clocks using its database node before
browser authentication, retaining strict JWT time validation. Public source docs
now describe the exercised v1 commands. Browser defaults consume the same image
shape helper as SSH, while overalls derives its default image ID using the shared
manifest validator against the installed guest artifact. The completion candidate passes all 406 Marshall tests (39 properties and
367 tests), browser JavaScript checks and forced Dialyzer with the existing
exclusion. Full fleet verification remains pending.

The completion candidate's complete overalls system and `porsche-fleet.driver`
build successfully, including the framework's driver lint/type checks. The
isolated database/host freshness expectations remain unchanged from main's
ADR-0050 acceptance. Building the driver alone is not fleet acceptance; the full
runtime run remains the next verification step.


## Deployed completion revision

The updater recorded `5089dea893106b677f83a878d9b8fc4fce3cd9b1` healthy,
including authenticated Porsche readiness. Concurrent platform changes then
advanced main and overalls to `62db2d83ae7c3658e1b6a2a97d46a002efd7acbd`, also
recorded healthy. A fresh pinned native SSH PTY check on that deployment verified
correct CRLF approval/banner/prompt output. The Porsche application and SSH domain
sources are unchanged between those two revisions.

The running full fleet driver captures the completion candidate at `5089dea`;
its result must not be attributed to the subsequent integrated platform revision.
Full fleet acceptance and the final requirement audit are still pending; a live
process or an intermediate successful scenario does not establish that acceptance.


## Integrated check catalog correction

Review of integrated revision `62db2d8` found six duplicate attributes in the Nix
check catalog, including `porsche-fleet`. `nix-instantiate --parse` reproduced the
failure before evaluation. Removing only the identical duplicate declarations
restores parsing and catalog evaluation; all seven Porsche/administrative checks
remain explicitly exported among 55 checks. This preserves ADR-0046 and the
`explicit-check-catalog` contract without changing runtime behavior or test scope.

The captured completion fleet run passed the Porsche native/browser lifecycle
scenario in 205.92 seconds, failed-pool reporting/recovery in 12.52 seconds,
missing-image admission denial/recovery in 8.55 seconds, and three-node idempotent
creation in 32.37 seconds. Remaining scenarios are still running; these individual
successes are not yet a full fleet pass.


## Requirement audit

| Requested behavior | Implementation and executed evidence | Remaining boundary |
| --- | --- | --- |
| Independent SSH daemon beside Marshall | [Porsche supervisor](../../../porsche/lib/porsche/application.ex), independent release probe, dedicated NixOS service test, live overalls port 22 | Captured completion fleet passed; later platform integration has separate scope |
| Connection actors | [Connection actor](../../../porsche/lib/porsche/connection.ex) requires signed-key proof, owns one session and monitors the OTP connection; native proof/channel tests pass | Account authority remains in Marshall, not the process |
| Ash domain model and existing job execution | [Command dispatcher](../../../marshall/lib/marshall/ssh/commands.ex) wraps current authority, receipt and existing actions in one transaction; rollback/idempotency properties and real lost-reply fleet scenario pass | Full captured fleet recovery passed |
| Browser key add/remove and approval | Ash key/approval resources, LiveView tests and real browser fleet scenario pass; removed keys lose subsequent authority | No unresolved feature gap identified |
| Public LLM documentation | [Documentation catalog](../../../marshall/lib/marshall/documentation.ex) and controller tests cover public HTML/Markdown, command examples and `/llms.txt`; fleet HTTPS probes pass | No private gateway or account data published |
| Default image and machine shape | Shared Ash image helper, explicit-input preservation and browser regression tests pass in the 406-case Marshall gate | Deployment-specific image must remain registered |
| Property-based testing | Protocol key/parser properties, Ash authority history model, receipt/outcome model and Porsche wait/privacy models pass their project gates | Models do not substitute for physical execution |
| NixOS integration and deployment | Module/configuration, staged SSH handoff, secrets/rotation, authenticated readiness and updater checks pass; overalls activated automatically | Captured fleet revision differs from later concurrent platform integration |
| Logging, Fluent Bit and CloudWatch | Source redaction/metric properties, actual service-to-Fluent-Bit output and isolated CloudWatch transport checks pass | Live AWS/IAM/KMS and throughput are not claimed |
| Crash dumps | Four actual Porsche crashes, encrypted artifact bounds/retention and off-host decryption pass the dedicated NixOS test | Opt-in operator configuration; no plaintext cloud export |
| Correct terminal formatting | Native PTY regression plus pinned live OpenSSH check verify CRLF without doubled carriage returns; non-PTY bytes preserved | Existing sessions must reconnect after deployment |

No architecture decision changes arise from this audit. ADR-0046 is implemented;
its accepted scope and rationale remain unchanged.


## Final acceptance

The full nine-machine `porsche-fleet` driver exited successfully after 2093.74
seconds and cleaned up all its virtual machines. Captured driver:
`/nix/store/80w6aa6ydfcyfs8941b0h356451lkb6l-nixos-test-driver-overalls-porsche-fleet`.
Its source is the completion candidate committed as `5089dea`; the later merge's
unrelated ingress, resizing and relocation changes are outside this result.

All scenarios passed: migrations and host observations; Porsche browser/native
SSH lifecycle and lost-reply recovery; unavailable storage/image denial and
recovery; three-node idempotency; capacity races; allowed egress and same/cross-host
isolation; real Lilly release upgrades; encrypted credential-only rotation;
browser sharing/terminal recovery; Marshall loss and PostgreSQL outage; Lilly
daemon death; disk identity and confirmed cleanup; stale and revoked authority.
The Porsche-specific scenario passed in 205.92 seconds. This uses real KVM,
Firecracker and ZFS, with multiple virtual hosts on one physical test host.

All four project gates passed for the completion work: Protocol 74 cases, Lilly
216, Porsche 57 and Marshall 406. Property tests, compiler/runtime/contracts/ADR
gates and Dialyzer ran; Marshall retains its existing documented exclusion.
Focused NixOS service, secrets/rotation, administrative port migration, updater,
collector and encrypted-crash checks passed as recorded above.

Live overalls recorded `a1bc2da` healthy after the check-catalog correction.
Public `/docs`, `/docs.md` and `/llms.txt` returned HTTP 200 with HTML, Markdown
and plain-text content types respectively. Pinned OpenSSH PTY verification passed
against the deployed service. The final changes update evidence and ADR-0046's
implementation status; they change no runtime behavior.

No required Porsche implementation item remains open. Live AWS/IAM/KMS delivery,
production throughput and verification of unrelated concurrent platform work are
not established by these results and are not claimed as Porsche acceptance.
