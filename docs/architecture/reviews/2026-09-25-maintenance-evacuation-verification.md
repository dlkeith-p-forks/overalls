# User-operated maintenance evacuation verification

## Scope and architecture impact

Campaign024 uses one worktree and branch `verify/024-maintenance-evacuation`,
starting from published `e3072688`. Accepted ADR0061 continues to govern fixed
cohorts, downtime consent, worker authority and physical readiness. The correction
retains existing user control authority through its transaction. No domain,
schema, protocol, storage, permission or deployment decision changes. All
replicas must receive the repair before relying on its ordering guarantee.

## Existing evidence and baseline

The existing evacuation examples cover request idempotence, fixed cohorts,
maintenance admission exclusion with serving enabled, requester demotion, pause,
per-item stopped-copy approval, replan revisions and empty-host freshness. Existing
stop-in-place drain properties cover duplicate/reordered outcomes. Existing native
relocation tests separately cover running/stopped copies, data, source restoration
and serving publication. None proved the combined browser campaign path or
transactional control-versus-actor revocation ordering.

Unchanged published source failed the first two-order pause/elevation schedule:
3/4 focused checks passed (two properties and control-first), seed24002,17.4s.
The lock-first pause waited and still succeeded after elevation was locked. This
is an overlapping-request finding; fresh requests begun after completed revocation
were separately refused.

The first expanded schedule run was invalidated by fixture cleanup omitting
`ingress_endpoints`; cleanup failures masked most action outcomes. That disposable
`marshall_test_verify024` database was explicitly reset before the correction.
The prior residue was removed by reset, not proven clean by the corrected helper.
A corrected unchanged-source matrix then passed7/13,seed24004,6.5s: all six
revocation-first pause/approve/replan x elevation-lock/sign-out cases failed;
all control-first cases and the real VM-before-User guest identity consumer passed.
The corrected baseline's own post-run audit found zero VM/campaign/item/host/
ingress rows, fixture triggers and advisory locks.

The final unchanged-source matrix includes requests: seed24010 passed8/16 authority
schedules in7.4s, with6 other tests excluded. All eight revocation-first request,
pause, approval and replan cases across elevation lock and sign-out failed; all
eight control-first cases passed. The tag selected every authority schedule
because ExUnit matches its presence, including a false value. SQL waits and final
outcomes are measured; the late User foreign-key path is source-backed analysis.

## Correction and contracts

Evacuation requests retain their early administrator precheck, then acquire the
actor User row with FOR NO KEY UPDATE after locking all source cohort VM rows and
before campaign mutation. Idempotent receipts also acquire current actor authority.
Controls retain Host->campaign->User; approval and replanning retain
Host->campaign->item->VM->User. Each path rechecks Cedar after the actor lock and
holds authority through audit commit. Automatic advancement remains independent
of the requester's later authority.

This order is required by the real personal-terminal transaction, which takes VM
before GuestAccounts User locks. Ordinary provisioning/lifecycle references Users
through foreign-key KEY SHARE; NO KEY UPDATE permits those references while
excluding role/elevation/login writes. Account retirement takes installation and
target admission fences, Users then team/integration rows; physical VM deletion
runs in a later transaction. Retiring an evacuated host reacquires its already-held
Host before credentials, without taking a later User or VM lock.

Reviewed repository/Marshall/Compute/test/Nix contracts, public Ash evacuation
actions, Cedar admin_operate, account Security and sign-out, guest identity/SSH
roster, ordinary admission/lifecycle and account retirement. Actor locking must
not be moved before cohort VM locks, or added to durable worker advancement.

## Verification

Generated histories use real authorized actions with an independent
pause/authority/approval/revision/admission model. Every history crosses approval
invalidation, exact/stale request replay and accepted work after demotion. Refusals
and previews compare persisted operation/allocation/audit/job rows. A second
property varies host freshness, pool freshness and physical allocations both
before and after ready, and verifies resume/retire refusal until current emptiness.
These synthetic reports establish control-plane behavior, not physical cleanup.

The repaired source passed **24 focused checks (2 properties and 22 tests)**,
seed24011, in21.4s. The distributed schedules cover both authority orders for all
four command families, pause before/after admission, duplicate workers, duplicate
requests, the real VM-before-User consumer and deliberate in-flight assertion
failure. Refusal observations include full source/cohort VM and campaign/item
versions, placement, operation, reservation, address, relocation, slots, lifecycle,
audit and administrative job rows. The failure probe preserves the original
assertion, releases gates and drains both operations before checking cleanup.

A required mutant moved only approval actor retention before its VM lock. Seed24007
failed the compatibility schedule with PostgreSQL **40P01 deadlock**, while13 other
checks passed, in13.3s. The oracle observes an actual ungranted transaction-ID wait
on the VM holder. Correct late actor ordering was restored before final testing.
The same disposable database's final audit found zero VM/campaign/item/host,
ingress endpoint/access grant, reservation/relocation/slot/job rows, fixture triggers
and database advisory locks. No evacuation peer BEAM remained.

That inventory did not include automatic agent registration. Later review found
167 orphan root/thread/audit rows and167 rows in each of their two version tables
after prior focused/full runs; those167 rows are not all attributed to this new
fixture. The new helper now removes only its own VM's agent history before deleting
the VM, and both refusal inventories include those five tables. The deliberate
failure probe now provisions a real eligible workload. Seed24012 passed24 checks
in32.4s, including successful and failing schedule cleanup, while sorted full-row
digests and counts of all five preexisting tables remained exactly unchanged.
No database reset or removal of that earlier residue was performed.

Frozen tree `e4ded0aef61b64be77cf5067c1b71f4def64bc33` on `e3072688` completed
Marshall precommit: seed396248, **1159 passed (122 properties,1037 tests)**,
2 excluded, in609.8s. Contract/browser checks passed and forced Dialyzer reported
0 errors,0 skips and0 unnecessary skips. The complete log ends `done (passed
successfully)`; after an interruption the tool session no longer existed, so its
original exit status could not be re-polled. This gate predates the helper cleanup
extension and native fixture lookup correction; the production repair is unchanged.

The native driver build passed in286s with strict browser JavaScript, standalone
Python checks and NixOS-composed driver typing. The first driver build failed on
an unvalidated Python mapping lookup before runtime; the browser now validates
string keys before lookup. A built driver is not recorded native execution.
The exact frozen driver subsequently built in292s. Runtime
`wn1pvgxw2pbg22ycbcncwki4pap130x8` failed in304s after native guest creation,
running/stopped data setup and public HTTPS, before browser launch. The new
`evacuation-browser` fixture used the User default read with a compute actor,
which correctly raised `Ash.Error.Forbidden`. It now uses the named authorized
`internal_lookup` and verifies the seeded account is an administrator. A focused
execution of the actual helper module passed that lookup, normal magic-link JWT
subject and private0600 output checks. No authorization bypass or synthetic
elevation was added. Cleanup completed in3.40s and a subsequent exact executable
process scan found no QEMU or wrapped/unwrapped native driver.

The runtime archive is `1790388985055-2185063-0.jsonl`; this failure does not
establish the browser campaign or physical evacuation acceptance. The composed
driver, standalone Python/JavaScript and installed operator, terminal, relocation
and Audi guest helpers were compared with captured source. Agent mode is disabled.

Integrated upstream `73a3a96c` before the next capture. Its allowed-host addition
uses the existing typed registry and unchanged authority/network mechanism. Its
Underclass pin, generated options and explicit `underclass-token-recovery` gap
are preserved; no Underclass runtime acceptance is claimed here.

Captured tree `9c7954620527c65fa859b985b949bec4f367bc25` on `73a3a96c` passed
**52 integrated checks (9 properties and43 tests)**, seed24013, in41.6s. This includes
the evacuation suites and handbook/HLDD checks after the cleanup extension.
Forced Dialyzer reported0 errors,0 skips and0 unnecessary skips in69.27s; the
persisted command exit was0. The five preexisting agent tables retained exactly
the same167 rows and full-row digests. All-file prek, ADR/HLDD/coverage/views/options
and Nix hldd/python-static checks passed. The strict native driver build passed
in306s; artifact comparisons passed before execution.

The second runtime `1icjkjfyn5rp4gi3q9cifvnxmck654si` used that exact capture.
It completed fleet boot in62.51s, actual capacity in125.68s, two ordinary guests
and durable data setup in117.95s, ordinary browser preview/forged refusal in12.02s,
and elevated request/pause in11.30s. Continue repeatedly produced
`evacuation.blocked` with `source_unavailable`: the new driver's enrollment
omitted `transfer_endpoint`, so the existing relocation guard correctly refused
the source. The coordinator interrupted its exact Nix client before the1800-second
move deadline. This is neither a passing native campaign nor an observed assertion
timeout. Its tool session exited1 after interruption; all owned native processes
were drained, with an unrelated ZFS runtime left untouched.

The driver now follows the established enrollment fixture: it waits for the
dedicated transfer service, validates the actual canonical IPv4 interface address
and Ed25519 public-key blob, enrolls the address/2223/key pin and checks exact
persisted equality. Both Lilly peers must reach each other's listener. These
checks establish fixture configuration and reachability only; permit/key/stream
authority still comes from the unchanged relocation protocol.

Source review also checked stable desired/observed state, no pending lifecycle,
fresh execution-ready host and ZFS pool observations, source disk/compute holds,
free transfer slots, destination normal maintenance mode, profile readiness and
measured disk/compute admission. Production Lilly already enables the dedicated
2223 listener and firewall. No eligibility requirement, capacity observation or
authentication check was weakened to admit the fixture.

Integrated published `236563f6` (including023 and027) before the next capture.
The separate default-false agent CLI variant and its strict type gate remain
intact; its older-image override does not apply to this non-agent journey.
Brady cache changes and historical evidence remain separate. Tree
`f9a700d1210db3a01e817ab90fbc39f2c738442f` then passed **55 integrated checks
(12 properties, 43 tests)** in70.1s, seed24014, including inherited agent CLI
histories and the same evacuation/handbook checks. Exit0 and exact unchanged
five-table agent digests were recorded. All-file prek and structural checks passed.
Published `8a575060` adds026 backup operator test/documentation evidence, with no
application source change; it is integrated before the final driver build.

## Recorded native evacuation

**Native browser evacuation passed all seven stages** on frozen tree
`384b0fa93a71c7e998de28ec7a9c8e6ebbb47de2`, based on published `8a575060`.
The exact runtime is `w9ch4asq6syq7rlbb2l8fqszd4zn6kak`; its strict driver is
`9hkd9kyqsprjhrcn9mxc5hbrc9hhgm8p`. The driver reports **587.51 seconds** for
the complete script; the seven stage durations sum to **587.24 seconds**.
Cleanup then completed in **3.98 seconds**.
The Nix command and tool session both exited 0. All 15 recorded process/start-time
identities were absent afterward, including the driver and all nine QEMU machines;
the coordinator independently confirmed cleanup. The unrelated native test was
left intact.

| Stage | Passing execution |
| --- | --- |
| Real fleet boot, ZFS and nested KVM | 54.59 seconds |
| Authenticated capacity, real transfer pins and peer connectivity | 110.59 seconds |
| Two ordinary guests and durable source data | 110.73 seconds |
| Ordinary browser preview and forged mutation refusal | 12.87 seconds |
| Elevated request, fixed cohort and paused admission while serving | 12.61 seconds |
| Running/stopped moves, physical cleanup, data and public ingress | 264.70 seconds |
| Fresh elevation, restored admission and stopped-guest restart/data | 21.15 seconds |

The running guest used baseline/final pre-copy and a fenced source stop. Both
relocations committed and finished on the destination. Assertions inspect exact
VM/owner/team/image/profile/shape, address and ingress identities; absent source
datasets and guest units; released source compute/disk/temporary holds and transfer
slots; and a fresh empty native pool allocation report. Destination marker/counter
checks and public HTTPS passed. The HTTP fixture process is explicitly restarted
after relocation's guest reboot; this does not prove application-process survival.
The stopped guest remained stopped until the final ordinary lifecycle request,
then booted on the destination with its data intact. Resume did not move either
guest back. Ordinary accounts remained non-administrative throughout.

The strict driver plus Nix HLDD/Python checks passed in 235 seconds before launch.
Installed browser Python/JavaScript, operator, terminal, relocation and Audi
helpers matched captured source bytes; the composed script matched its source
fragments. The installed listener uses port 2223 and the actual enrolled key path.
The source remained frozen during execution. Raw and compressed native transcripts,
PID/start inventory, exit status and cleanup record are retained as
`/tmp/verify024-native3.log`, `.log.gz`, `-pids.json`, `.exit` and `-cleanup.json`.
This capture predates the independently published `951630ee` clone-restart repair;
integration must preserve that distinction.

Final architecture review finds no changed decision or protocol boundary: the
authority correction restores ADR-0058/0061's current-control requirement while
preserving ADR-0037 transfer and physical cleanup authority. The real
VM-before-User consumer and deadlock mutant support the retained lock order.
Accepted rationale and ADR-0061's partial implementation status remain unchanged.

## Remaining gaps

The bounded NixOS browser campaign now passes. Native per-item full-stop approval,
replanning/cancellation and interruption permutations remain separate from the
generated control histories and earlier relocation failure evidence. Hardware
passkeys, physically independent Lilly machines, Ubuntu evacuation and deployment
acceptance remain separate. Existing native relocation failure evidence retains
its original revision and scope.
Inception tests and validation are excluded from this campaign by the user as of
2026-09-26, rather than pending acceptance.

## Coordinator integration scope

Integration includes published `bb83bfc2`, with the independent `951630ee` clone
restart recovery and `031` CLI permutation repair. The evacuation implementation,
properties, schedules and native driver sources are byte-identical to passing
capture `384b0fa9`. The newer Lilly readiness implementation retains its separate
upstream evidence; the evacuation runtime result is not relabeled as a run of
that implementation. The upstream native fault wrapper is enabled only for the
cloning variant, and its extra flag belongs to the legacy driver branch. Both
are outside the selected maintenance driver. Accepted architecture remains
unchanged: current administrative authority is retained through commit with
the existing VM-before-User order, and physical relocation authority is preserved.

Coordinator ADR/HLDD/generated-reference, contract and all-file prek gates passed.
The integrated Nix HLDD/Python checks and strict maintenance driver build exited0;
the built driver `qpksjbxw92pa5cn4429764y658imm2w9` has a byte-identical
`test-script` to executed driver `9hkd9kyqsprjhrcn9mxc5hbrc9hhgm8p`.
This is combined-source build and type evidence, not another native execution.
The integration transcript is `/tmp/verify024-coordinator-gates.log`.
