# Default OSS creation verification

## Scope and architecture impact

Campaign improvement 006 verifies the existing default at the two user entries:
the browser form and native Porsche SSH `new`. Explicit Customer creation remains
allowed for the authorized owner. Its persisted profile continues to deny sharing,
foreign reads, agent registration and guest-initiated egress.

The sole runtime correction maps Customer sharing rejection to the existing
HTTP 403 `forbidden` response instead of generic service unavailability. No
schema, authority, wire-value or profile-policy decision changes. The tests
preserve [ADR-0046](../decisions/0046-porsche-ssh-management.md) request
identity, the isolation requirements carried through
[ADR-0069](../decisions/0069-brady-egress-cache.md), and
[ADR-0103](../decisions/0103-profile-scoped-agent-capabilities.md) agent capability
authority. This extends the evidence in the
[default change review](2026-09-25-default-oss-creation.md).

## Inspected contracts and findings

**Corrected user-visible refusal (medium).** Customer sharing rolled back with
`sharing_not_allowed`, but `MarshallWeb.SSHAPI.respond/2` did not recognize that
expected domain reason. It returned HTTP 503 `temporarily_unavailable`, so Porsche
reported a transient service problem for an immutable policy refusal. The
endpoint regression reproduced 503 rather than expected 403 with seed 44006:
13 of 14 checks passed before the fix. The correction preserves the existing
opaque `forbidden` response and adds no new diagnostic or protocol value. The
regression and native journey require no sharing grant, change receipt, grant
audit version or SSH request receipt after denial.

The SSH receipt contract compares normalized explicit inputs before resolving
defaults. Omitting `--profile` and explicitly supplying `--profile oss` are
different semantic inputs. Retries with changed inputs must conflict even when
both would create an OSS VM. Presentation and wait options remain outside that
identity. Generated histories exercise those rules with a fixed replay and
conflict prelude, arbitrary subsequent attempts, and assertions on the persisted
profile, VM, reservation, operation and receipt. Each retry and conflict also
compares the complete sandbox inventory of durable IDs, including archived VMs;
returning the original receipt cannot conceal a second identity.

Browser histories use an independent last-choice model through explicit profile
changes, refresh, reload and repeated submission. They assert that the omitted
initial selection is OSS and that replaying the same draft produces one durable
VM and one provisioning operation. These application fixtures have synthetic
images and do not establish execution or networking.

The inherited fleet user seed leaves the first-login administrator bootstrap
incomplete. That seed cannot establish ordinary-user native behavior. The new
`default-oss-users` fixture action establishes a distinct, unused administrator
and completes the installation latch before any login. SQL assertions require
all three journey accounts to remain ordinary before login, after browser key
registration and creation, and after the Customer refusals. Existing fleet
variants and their historical evidence are not relabeled by this change.

## Native journey

`default-oss-creation` reuses the fleet's actual source-built services and nine
NixOS nodes: three Marshall replicas, PostgreSQL, verified HAProxy, two Lilly
provisioners, a browser/OpenSSH client and a local DNS/HTTP origin. Its separate
composed driver retains the NixOS framework's type and lint checks. Existing
fleet variants still have separately documented legacy typing debt.
The variant selects the existing Audi-enabled fleet image and starts its real
private trust, DNS and guest-account bootstrap prerequisites. No missing trust
receipt or guest readiness check is bypassed.

The browser registers owner and member keys through the real settings page and
submits the untouched OSS selection after reload. Native OpenSSH reaches the
packaged Porsche gateway to create another VM with no profile option, replay
its request, reject a Customer change to that receipt, and create an explicit
Customer VM. SQL verifies all persisted profiles and single creation effects.
The same owner/key/recipient first shares OSS, permits the member read and
revokes that access. Customer owner reads succeed; sharing and a member read
receive exact `forbidden` responses, with no grant/change/request rows or new
grant audit versions. The actual packaged Marshall
conversation API refuses the Customer owner, whose VM has no agent root, while
both OSS VMs have roots.

Privileged fixture PTYs authenticate each actual Firecracker boot solely to run
fixed network probes. Both OSS guests must resolve the local fixture name and
receive the expected HTTP body. Customer direct-IP and DNS-based HTTP must time
out. Both hosts check the live origin first; an OSS guest repeats its positive
control after the Customer denial. These probes do not claim guest-user SSH or
browser-terminal authorization, provider inference, arbitrary packet encoding,
independent physical failure domains, or production deployment acceptance.

## Execution record

Initial focused application run in the pinned devenv shell: **19 passed (3
properties, 16 tests)**, seed **44006**, 9.9 seconds. After reproducing and fixing
the SSH policy-response defect, the combined endpoint and generated-history run
reported **33 passed (3 properties, 30 tests)**, seed **44006**, 11.4 seconds.
After strengthening the SSH inventory oracle, the same focused suite passed
**33 checks (3 properties, 30 tests)** with seed **44006** in 16.8 seconds.

The final branch incorporates pushed main `00343832` (improvements 004 and 005).
Review of the production diff from the first native candidate's base `6083aeda` found
only Teams creation changes and the Source code navigation link; 005 changes no
production application code. None changes VM admission, profile resolution,
sharing, Porsche transport or guest networking. The immutable native artifact
therefore identifies its precise source scope. That candidate did not complete
native acceptance; the corrected fixture is built on integrated `00343832`.

Integrated Marshall `mix precommit` passed with **1,029 passed (94 properties,
935 tests), 2 excluded**, seed **92073**, in 332.7 seconds. The distributed tests
were included; host-dependent exclusions remain separate. Browser-state checks
passed. Forced Dialyzer reported **0 errors, 0 skips, 0 unnecessary skips** after
the worktree's PLT refresh. Later edits record native fixture findings and
execution evidence without changing the application or properties exercised by
this run.

The initial native driver build correctly rejected an obsolete framework class
import before machine execution. The driver now uses the pinned framework's
`QemuMachine` type and its strict type/lint checks passed. The first machine run
reached real enrollment then correctly rejected Ziggy credential issuance before
host enablement. Fixture ordering now follows observed capacity, explicit host
enablement, then private-service credentials. The next build was stopped before
machine execution after the policy-response defect and the browser login route
were corrected.

The next immutable attempt used
`/nix/store/isnxr65ylhkazsfnynq0m02047syvn27-vm-test-run-kittens-default-oss-creation.drv`
and reached browser admission, but guest trust delivery repeatedly timed out.
The selected base check image was built with empty `privateServiceRoots`, while
the fleet's Lilly configuration requires nonempty boot-time trust delivery. The
base image lacks the receiver needed to satisfy that contract. The attempt was
stopped after two observed 120-second trust failures; it establishes no native
acceptance. The new variant now selects the existing complete Audi fleet image
and its issued private-service prerequisites. Other fleet variants' claims are
not upgraded.

**Native default-OSS journey passed in 435.39 seconds**, with cleanup in 4.07
seconds and Nix exit 0. The strict composed-driver type and lint checks passed.
The immutable source snapshot is
`/nix/store/wvqzn780iix5bzvdjhb0nlp3if490xjf-source`; the executed derivation is
`/nix/store/2czpvqhb6v28sd1fl9v94xxvr7szn35l-vm-test-run-kittens-default-oss-creation.drv`
and its output is
`/nix/store/2zdq0bi26dvip3vq26jsz2jmf8v48i88-vm-test-run-kittens-default-oss-creation`.
It contains integrated `00343832`, the Customer response correction and the
complete private-service fixture. All six subtests passed: fleet startup,
authenticated native capacity and private-service prerequisites, ordinary browser
creation, Porsche creation/replay/conflict, Customer authority refusals, and
actual guest egress. All three boots received current trust and remained running;
the final network subtest passed in 8.97 seconds. Later changes only record this
execution and the separate campaign 011 gap.

Final static gates passed: ADR structure and links (120 decisions), HLDD review
receipts and references, generated options/coverage and Ash/deployment views,
contract structure and source coverage, and `git diff --check`. All-file `prek`
passed in the pinned devenv shell, including every fleet logging hook, Ruff
format/lint and `ty`. The Nix `checks.x86_64-linux.hldd` gate passed, including
evaluated deployment placement. These checks validate maintenance and static
properties; the scoped application and native executions above establish the
runtime evidence.

## Remaining scope

**Separate fixture gap (campaign 011).** Source inspection confirms the same
base-image/host-trust mismatch in current catalog variants `fleet`,
`porsche-fleet`, `cloning-fleet`, `brady-fleet`, `customer-isolation-fleet`,
`relocation-fleet` and `ubuntu-fleet`. Checks receive packages built with empty
`privateServiceRoots`; the NixOS private-service module and Ubuntu unit enablement
then omit the trust receiver, while every fleet Lilly supplies nonempty roots.
Only the rejected 006 candidate reproduced the runtime failure. These seven
variants were not rerun here. Their historical feature-scenario passes retain
their original revision and scope and do not establish current fixture
acceptance. Campaign 011 must correct the shared fixture and record actual
NixOS and Ubuntu boot-trust readiness. This change repairs only 006's selection.

The new native scenario uses NixOS guests only. The isolated local HTTP/DNS
origin proves this creation-to-egress path; it does not rerun the broader
cross-host peer/spoofing/IPv6 matrix, Brady interception, Customer owner guest SSH,
or hostile agent-tool execution. Their existing scenarios remain separately
scoped. No production action is authorized or performed by this check.
