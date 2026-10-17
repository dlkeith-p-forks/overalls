# Clone restart recovery

## Scope and architecture impact

This change repairs restart readiness and extends recovery evidence on top of
`9a0b3429`, integrated with upstream `ddf1d05a`. The intervening Underclass
package pin, agent CLI, cache and backup verification and handbook evidence do not change the
production clone or restart paths. The added fleet variant defaults off for
`cloning-fleet`; its agent provider diagnostics are outside this scenario.
It includes the preceding
[production acceptance record](2026-09-25-production-clone-relocation.md).
Marshall's Ash clone coordinator and Lilly's Ash execution journal remain the
state machines. There is no new framework, protocol, migration, placement rule,
capacity policy or recovery authority.

Affected decisions are [ADR-0017](../decisions/0017-durable-vm-actors-and-host-ownership.md),
[ADR-0055](../decisions/0055-queued-machine-cloning.md) and
[ADR-0092](../decisions/0092-portable-workload-bundles.md). The ZFS accounting
requirements inherited through ADR-0031/0035/0037/0050 remain in force. Accepted
rationale and implementation statuses are unchanged.

## Findings and implementation

**High, repaired: restart collapsed retryable storage observations into terminal
failure.** [Disk.ready](../../../lilly/lib/lilly/vm/disk.ex) previously returned
`disk_not_ready` for a `storage_busy` result from native readiness inside the pool
lock. Initial provisioning already preserved that result. Restart now does too.
The existing executor returns a retry to the actor; no nested retry loop was
added. Disk and bundle validation still precede boot preparation and persistence
of launch-attempt authority. Invalid ownership, missing disks, malformed bundles
and unclassified failures remain terminal.

[Native readiness](../../../lilly/lib/lilly/host/zfs_dataset.ex) emits the
catalogued `vm.disk_readiness_failed` event with placement identity and fixed
stage/reason atoms. Stages distinguish dataset identity/ownership, snapshot
ownership, accounting, mounts, disk metadata and boot bundles. Reasons are
`invalid` or `unconfirmed`. Usage contention and confirmed owned import staging stay quiet. No native output,
paths, credentials, disk contents or arbitrary error values enter this event.
The other callers of child verification (initial preparation and resize) still
fail closed and retain their existing outer error contracts.

**High, additional repair: owned receive staging can block
source readiness.** A fresh same-pool clone failed accounting validation while
its independent destination was being received. Whole-pool accounting expects
ordinary mounted datasets, while an incoming dataset intentionally remains
unadopted and read-only. The new
[local journal inventory](../../../lilly/lib/lilly/transfer/import_journal.ex)
and [staging check](../../../lilly/lib/lilly/transfer/received_dataset.ex) defer
restart only for a current native pool, exact destination host/pool/placement,
private active journal, matching native nonce and bound GUID (or the still-unbound
receiving GUID), and absent ordinary active/retired claims. A validated unbound
receiving journal also defers while its native dataset and canonical mountpoint
are absent: receiver preparation releases the pool lock before the stream starts.
A missing previously bound dataset does not qualify. This closes creation during
a readiness observation without granting the journal effect authority. Adoption
ends deferral.
Malformed, foreign or replaced state does not earn a retry classification.

The target's portable bundle, disk metadata, native ownership and mount checks
precede this deferral. Full snapshot/accounting validation still precedes launch
after staging ends. The check grants no execution, transfer or capacity authority;
it does not generalize unconfirmed accounting or unmounted neighbors to retries.
Only the existing actor reconciliation retries. The native fixture exercises
owned staging, mismatched GUID/nonce and malformed journal/bundle refusals, then
restarts under the same generation after adoption. This follow-up changes no
accepted decision, wire schema or persisted journal format.

**High, additional boundary repair: deferral depended on coherent parent
accounting.** The staging check called `ZFS.inspect_path/1`, whose policy check
requires physical usage decomposition. During receive this could reject an
otherwise matching parent before independently owned import intent is examined.
The narrowly scoped `ZFS.staging_identity?/1` verifies canonical mount, GUIDs,
policy, numeric bounds and healthy backing extents without usage decomposition.
Only the owned-import deferral caller uses it. Ordinary identity inspection,
accounting, admission and readiness after adoption remain strict; success grants
no ownership, capacity, effect or execution authority. A fixture-only observation
mode changes parent `used` bytes without changing native state. It asserts strict
inspection refusal, preserved identity, retry without launch and terminal malformed
journal refusal. The captured production tree at the earlier failure is unavailable;
this code dependency is confirmed, but its causal role in that failure is unproven.

**Historical trigger remains unproven.** The older production clone recorded
`disk_not_ready` at source restart. Its logs do not identify the rejected
predicate. This propagation defect is confirmed from code; it does not establish
that contention caused the historical failure. Subsequent network cleanup
warnings are not evidence of the original disk failure.

Clone cleanup still requires source restoration, endpoint revocation and stream
quiescence, snapshot pruning and destination settlement before releasing slots.
Explicit retry retains the snapshot and published destination, and cannot
overwrite a newer source generation. Terminal failures require supported user
retry; deploying this fix alone does not revive them.

## Verification scope

- [Actor properties](../../../lilly/test/vm/actor_test.exs) generate transient
  retry sequences, actor restarts and eventual success or terminal failure. They
  check durable observations and exact placement/epoch/generation authority.
  These are journal tests with a controlled executor, not VMM evidence.
- [Clone properties](../../../marshall/test/marshall/compute/cloning_test.exs)
  exercise real Ash/PostgreSQL transitions and authenticated duplicate effect
  receipts, publication with failed source restoration, explicit retry, newer
  source intent and cleanup order. Physical outcomes are synthetic in this test.
- [Native restart fixture](../../../nix/verification/tests/machines/zfs-guest/restart.exs)
  distinguishes a held pool lock from coherent usage changes returned by a
  fixture-only [utility wrapper](../../../nix/verification/tests/support/zfs-readiness-fault.py).
  It checks that retries leave boot/launch-attempt files unchanged, preserve
  authority and keep the VMM stopped. Missing disk/bundle and malformed bundle
  cases remain rejected. The same generation then boots and reads guest data.
- [Native clone fixture](../../../nix/verification/tests/machines/zfs-guest/cloning.exs) now
  restores its source through production `Driver.restart`, preserving the
  portable-bundle boundary. It also checks same-pool owned staging and terminal
  malformed/foreign evidence before same-authority restart after adoption. The
  final fixture also covers the prepared-receive window before native creation.
- [Porsche fleet](../../../nix/verification/tests/machines/fleet/scenarios/porsche.py) arms a
  fixture-only native launch refusal for the source. It verifies publication,
  retained slots, refused transfers from the independent destination, public
  retry, source disk identity/data, destination process preservation and cleanup.
  The subsequent clone and bidirectional relocation journey checks admission
  resumes. No fixture writes a physical outcome or clears a slot in PostgreSQL.

Focused actor tests passed: 16 passed, including one generated retry property.
Focused clone tests passed: 14 passed, including two properties. Native and full
component execution results are recorded below. Test presence alone does
not establish a passing run. Production recovery and renewed acceptance remain
open until deployed revisions and physical outcomes are observed.

Lilly `mix precommit` passed: 408 tests (49 properties, 359 examples), compiler,
formatting, logging/contracts and forced Dialyzer with zero errors or skips.
Marshall `mix precommit` passed: 1136 checks (121 properties, 1015 examples),
2 excluded, seed 257364, 604.5 seconds, partition `_clone_recovery`. Compiler,
formatting, logging/contracts, browser asset checks and forced Dialyzer passed;
Dialyzer reported zero errors, skips or unnecessary skips.
After integrating `08ae4faa`, the clone and new agent CLI history tests passed
together: 17 checks (5 properties, 12 examples), 36.0 seconds. Production
implementation was unchanged by that merge.

All-file `prek` passed logging checks, Ruff formatting/annotation checks and the
configured `ty` scope, including the new ZFS observation wrapper. The legacy
composed fleet driver retains its existing `skipTypeCheck` setting. Its complete
captured script nevertheless passed a separate pinned `ty` check against the
real NixOS driver types, with Python 3.13 and only `unused-ignore-comment` disabled:
two pre-existing shared fragment directives become unused after composition.
No type-error rule was suppressed. This is recorded manual verification, not
automatic enforcement of the legacy fleet gate. ZFS's composed driver retains
the framework type gate.
The first native candidate stopped before the restart scenario: the source-built
image minimum was 3,244,294,144 bytes, exceeding the fixture's fixed 3 GiB disk.
The fixture now uses the manifest minimum and explicitly requires room for its
existing growth-to-4-GiB scenario. Production admission is unchanged.

The second native candidate passed `restart-contention 3`, the subsequent
same-generation guest restart and data read, crash recovery, neighboring guest
preservation, cancellation restoration, capacity, resize, missing data-drive
refusal and the single-disk clone independence case. It then reached the global
one-hour deadline during the final multi-disk clone case and exited 143. The full
check failed; this is not a full-suite pass. The full NixOS ZFS journey now has
a bounded four-hour global deadline, with all individual operation deadlines,
assertions and other fixture variants unchanged. Its fresh full rerun is pending.
The two-hour candidate was interrupted after 317 seconds to use the requested
four-hour limit on the integrated candidate; this interruption is not a test pass.
The next candidate was interrupted after approximately 40 minutes to include the
new owned-staging repair; it is not a completed test run. Both affected native
checks were started again against that repair at 04:25 UTC.
The second candidate's captured readiness diagnostics contain one `disk_metadata` and two `boot_bundle`
failures for the missing/malformed fixture cases, all with `reason=invalid` and
only placement identity. The contention attempts emitted no readiness failure.

Native `cloning-fleet` passed in 1177.65 seconds. This includes the injected
failed source restoration, retained slots and blocked admission, public Porsche
retry, preserved destination, subsequent clones, bidirectional relocation,
independent contents and clone audit after source deletion. The output is
`/nix/store/hmv9whs65ihxsqaplzl6v85naw7d3ila-vm-test-run-overalls-cloning-fleet`.
Its captured source precedes the unrelated Underclass and agent CLI integration;
the relevant runtime and selected fleet behavior are unchanged by that integration.
The evaluated `2d66e76d` fleet script differs only by a final blank line from
the completed run's script. The updated fleet expression evaluates successfully.

The owned-staging candidate passed Lilly `mix precommit`: 410 checks
(50 properties, 360 examples), 16.8 seconds, and forced Dialyzer with zero errors,
skips or unnecessary skips. The focused journal/received-dataset/ZFS/actor group
passed 41 checks (six properties, 35 examples). All-file Python/logging/contracts
and ADR/HLDD options, scenario and topology checks passed; Nix HLDD produced
`/nix/store/w67n5g6653cr81y2ywzb5hf83vjw622w-overalls-hldd-check`.

The isolated native owned-staging journey passed in 528.34 seconds. It used the
actual source-built ZFS VM and unchanged clone block extracted from the full
driver, with a bounded 1800-second driver deadline. It verified quiet deferral,
unchanged boot/launch evidence, malformed journal/GUID/nonce and bundle refusal,
same-generation restart after adoption, independent writes, source deletion and
surviving-copy reads. Its driver is
`/nix/store/kw9wxrv6d1cs695m16q91y5yfr0rrgvi-nixos-test-driver-overalls-zfs-guest`;
the captured Lilly/protocol source at
`/nix/store/wgypz31fhh8q3wmnpsakksqxz5vkb8ls-source` matched that candidate at
execution, before the subsequent prepared-receive correction.
This is scoped native evidence, not a full ZFS-suite pass. The full staging-candidate cloning-fleet passed in 1176.44 seconds at
`/nix/store/8axpfash4fzicf7a6cpij3nc1hb51i3x-vm-test-run-overalls-cloning-fleet`. The ZFS candidate was interrupted after about
24 minutes to include the prepared-receive timing correction found during final
review. Both native checks were relaunched for that final correction; their
results remain pending at this checkpoint.

Marshall precommit on the owned-staging candidate at `2d66e76d` passed 1163 checks
(126 properties, 1037 examples), two excluded, seed 527316, in 720.8 seconds;
forced Dialyzer reported zero errors, skips and unnecessary skips. Integration
through `8af8164f` adds terminal attachment tests and lexical Hegel evidence
recognition, without clone/runtime changes. The integrated component and
governance recheck is recorded separately.

The final prepared-receive native journey passed in 854.79 seconds. It used
`/nix/store/8jihvnkh912pxy1wkp0n4m2cqysplgqb-nixos-test-driver-overalls-zfs-guest`
and captured source `/nix/store/wgv2b62j2852rf1xr9d5kk6x1amkm37z-source`.
The exact extracted customer-clone block passed the pre-native deferral and
missing-bound refusal, owned-staging and malformed journal/GUID/nonce/bundle
cases, same-generation restart, independent writes, source deletion and
surviving-copy read before final deletion. This is isolated native evidence;
the complete ZFS and fleet runs remain pending.

Final Lilly precommit passed 410 checks (50 properties, 360 examples) in
13.8 seconds, with forced Dialyzer reporting zero errors or skips. ADR, HLDD
reference/scenario/topology checks and all-file prek passed. Nix HLDD produced
`/nix/store/ijvgyhb65ip4h0l169amchp91a3hcwwf-overalls-hldd-check`.
Integration of `fff6587e` adds guest CLI candidate-start recovery and a separate
native fixture; it leaves Lilly, Marshall and protocol runtime code unchanged.
The running native checks retain their captured pre-integration guest package.
A second complete fleet run includes the integrated guest package. Upstream
`4bd7d237` adds secret-recipient verification and documentation only; it does not
alter any application runtime or the selected native clone fixtures.

Final Marshall precommit passed 1170 checks (132 properties, 1038 examples),
two excluded, in 872.5 seconds with the final Lilly dependency compiled first.
Forced Dialyzer reported zero errors, skips or unnecessary skips. The integrated
all-file Python/logging/contracts and ADR/HLDD reference/scenario/topology gates
passed again after `4bd7d237`. Nix HLDD on the preceding integrated candidate
produced `/nix/store/rvlncgixnzx1581amad85i30srmlk44f-overalls-hldd-check`.

The follow-up is published as an authorized checkpoint with these component and
isolated native results. Complete ZFS, captured fleet and integrated fleet runs
are still running; their pending status does not constitute a full-suite pass.
Production retry requires confirmed normal activation of this follow-up first.

The captured prepared-receive `cloning-fleet` subsequently passed in 1487.16
seconds at `/nix/store/p93kq3h26pbvap7n1zfcpsq3i1l8a2wj-vm-test-run-overalls-cloning-fleet`.
The integrated guest-package fleet also passed at
`/nix/store/f65hqczbi7ixak34v2j67dv6y8k2z21p-vm-test-run-overalls-cloning-fleet`.
These executions precede the parent-accounting boundary repair. That repair's
focused Lilly group passed 14 checks (three properties, 11 examples).
The full native `zfs-guest` journey then passed in 3589.48 seconds at
`/nix/store/fv43wh8bbs25kbbnvadypl58af4l7dmr-vm-test-run-overalls-zfs-guest`,
covering the parent-incoherent fixture: strict inspection refused the incoherent
parent, identity-only probing deferred restart three times without a launch
attempt or intent change, the malformed journal stayed terminal, and the same
authority restarted after fault removal and adoption. The fault incoherence and
its removal both observed exact private import ownership. Component gates,
native cloning-fleet, updater activation and supported fresh-clone recovery
records above predate this boundary repair.

## Production recovery record

Read-only inspection at 02:28 UTC on 2026-09-26 confirmed clone
`fd660424-11a0-4087-ae91-a659320b6fac` still in `cleaning`, with
`source_restart_failed`, no restoration timestamp and its original published
destination. Its domain request key is
`a0f11477-5526-4af7-a062-32d842b6164b`. A read-only SSH receipt lookup found no
Porsche request for this clone; Porsche `request show` for that key returned
`not_found`. Therefore the plan's assumed Porsche recovery route is unavailable.
The existing browser/Compute Ash retry remains the supported coordinator entry.

At 02:32–02:37 UTC the source remained generation 6, epoch 1, placement
`77d84d25-76da-4029-8b7c-61f1e8eb9e5f`, desired running and observed failed.
Its unit was inactive. Native dataset GUID `16685052377969033445`, host/pool tags
and the local ready claim matched; retained snapshot `@lilly-b` had GUID
`13541204413672475608`. The destination remained running at generation 2,
placement `6a842974-c21b-4618-a7a5-2594700109af`. These are identity observations,
not a claim that every readiness predicate passed.
Read-only inspection at 03:08 UTC reconfirmed those source/destination generations,
the original failed operation, active cleaning phase and one retained transfer slot.

At 03:45–03:46 UTC, before any recovery mutation, that clone and its original
source/destination were absent from PostgreSQL. There were zero clone records
and zero held transfer slots. The same Overalls host and parent pool GUID remained,
but the pool had no child datasets or snapshots. Porsche refused the original
source as unavailable; the current inventory instead contained three newer VMs
on Dungarees. This external state change prevents recovery of the original clone
and is not evidence of supported retry, source restoration or cleanup. This task
did not delete those records or disks, clear slots or fabricate outcomes. The
operator was asked whether the fleet had been reset or replaced.

Implementation commit `951630ee6b169a3ce981ef631137e5bc6db6cc9b` was pushed to
`origin/main` at 03:45 UTC after upstream integration, ADR/contracts checks,
all-file Python/logging/HLDD gates and Nix HLDD passed. The ZFS rerun and production
acceptance were explicitly pending. Dungarees' normal updater reported this
revision healthy at 03:47 UTC; Overalls was still building at that observation.
The actor retry property was subsequently tightened to observe worker termination
and synchronize through actor state instead of sleeping; all 16 actor checks
(one property, 15 examples) passed in 4.4 seconds.

Both hosts confirmed `951630ee` healthy through the normal updater: Dungarees at
03:47 UTC and Overalls at 03:51 UTC, with matching active and healthy system paths.
Lilly's final precommit after the synchronization change passed all 408 checks
(49 properties, 359 examples) in 11.1 seconds; forced Dialyzer again reported zero
errors, skips or unnecessary skips. Later upstream CLI/maintenance commits were
integrated without changing the clone/restart implementation; this production
run is not a frozen-revision experiment.

### Fresh production recovery and transfer acceptance

Fresh source `recovery-0926-0351`, VM `69b96e54-0157-4696-aedf-3672577aff95`,
was created on Overalls with NixOS, OSS, one vCPU, 512 MiB and 4 GiB. Guest SSH
and a synthetic persistent file passed. Clone `a20f3029-1c73-4517-b30e-ea8b3831b1b0`
published destination `recovery-copy-0926-0351`, VM
`3f6762bf-717e-4a54-8f5b-e76432ede1af`, but source restart failed. The new event
identified `stage=accounting`, `reason=unconfirmed` at 03:52:31.755 UTC. This was
not a `storage_busy` result, so the propagation repair correctly did not convert
an unconfirmed validation into launch authority.

Read-only native observation initially passed after publication; supported
Porsche retry nevertheless failed again at 03:56:15.962. Repeated observations
under Lilly's actual configuration and tool path then found a stable tree with
an unmounted neighboring dataset. That tree correctly failed native accounting.
Other `fastbase-*` workloads were being created and deleted concurrently on the
same host. Their cleanup later removed the neighboring dataset without intervention
by this task. At 04:02:08, both consecutive property trees and their accounting
passed, retaining the source GUID `17352425563408051899` and snapshot GUID
`2507139205573023697`. These later observations establish a concrete rejected
predicate, not the exact historical tree at either earlier restart failure.

A second Porsche retry restored the source at 04:02:40 and completed the clone
at 04:02:44. Both revocation receipts preceded snapshot pruning and completion;
native inspection found no remaining snapshot and zero held transfer slots.
The destination unit retained its original 03:53:22 boot. Guest reads verified
the shared captured contents, then different source/copy writes and marker files
proved independence. Source SHA-256 was
`f378c2ac0b871ea5a140adbf01e46e7233cdaa55d758331f7402f81a1d8f9b93`;
copy SHA-256 was
`4c22bc0083604c5776de903bebcdcb0ca5dd787df0d20891aada9f9d3cf3b88c`.

| Action | Porsche request identity | Actual outcome |
| --- | --- | --- |
| Create source | `6df8f134-a661-473b-8902-d2395c56247d` | Succeeded; exact replay retained VM and operation |
| Clone | `442dc485-6fb0-4b20-bb75-d0bf65463323` | Source restart failed; destination subsequently published and ran |
| Move published copy while clone slot retained | `296af65e-715b-4bd2-87e7-d3eff28724df` | Refused `source_unavailable`; no move admitted |
| First supported clone retry | `caeff306-3866-47b2-987a-90a3836d1974` | Failed accounting validation again |
| Second supported clone retry | `13e920ee-d467-41e2-8182-bf5a481d5d16` | Succeeded with restoration, preserved destination and completed cleanup |
| Copy Overalls → Dungarees | `da78aff0-17a3-444f-89d4-9eb5e39391e2` | Succeeded; same request replay retained relocation `d4587dfc-d060-4469-aaf6-0ddb32076705` |
| First opposite-direction attempts | `cf7df330-4b1a-4d35-a642-697898de2677`, `e6055f55-abce-44bc-8611-6eac71d46cdb` | Refused `insufficient_capacity` and `source_unavailable` immediately after cleanup; not slot-arbitration evidence |
| Fresh opposite-direction race: copy Dungarees → Overalls | `35d021ac-5063-4d1d-ba8d-34fae22ca7c4` | Succeeded at 04:13:17; guest checksum retained and old Dungarees dataset absent |
| Fresh opposite-direction race: source Overalls → Dungarees | `6a6050b7-4c52-4590-82d6-a6e4840b4050` | Refused `transfer_busy` |

Original terminal Porsche receipts remain immutable: replaying the first clone
request returns its original failed result and pinned destination even after the
separate retry receipt succeeds. The first relocation survived a polling transport
error, reached Dungarees with unchanged copy data, then retried unconfirmed old
source deletion until 04:10:31. Native inspection confirmed the old dataset absent
and no held slots. No database slots or restoration timestamps were edited.

Private command evidence is retained outside Git at
`/home/ghuntley/porsche-acceptance/recovery-20260926/`. Recovery must recheck source
generation, placement and native storage identity immediately before public retry.
The original older source and destination disappeared externally before recovery.
Fresh fixtures that encountered failures are retained for investigation; cleanup
of any subsequent entirely successful fixtures is recorded after it completes.

At 04:14:09, a same-source race admitted clone request
`a1185197-8934-4873-a9e9-9cf4dfa6e835` and refused competing relocation
`18928c8f-9824-452f-9855-7618ee7276e5` with `clone_in_progress`. Clone
`c0afab64-7deb-4855-8b3f-cfbc25c69154` again recorded source accounting failure
at 04:14:21.324. Its independent incoming destination was observed during native
receive/adoption at 04:15:17. This prompted the narrow owned-staging repair above;
it does not prove the exact native property tree at the earlier failure instant.
At 04:32 UTC the source was still generation 7, failed, with dataset GUID
`17352425563408051899` and snapshot GUID `12485411121829818840`. Its published
destination was running at generation 2 with GUID `533972745605228960`; guest SSH
verified the source-only file and checksum. One transfer slot remained held.
The supported retry was performed after verified deployment and another fresh
identity check, as recorded below.

### Prepared-receive deployment and supported recovery

Commit `186a1ea4c9e20f813eb3a07310212faa271d2ccb` was pushed at 05:22 UTC.
Both hosts activated it through the normal updater: Dungarees around 05:26 and
Overalls at 05:31:53. Their active system links were independently checked at
05:32:44. Supported Porsche retry `ab361c69-fd08-4ffe-aaf6-637fe50edf0d` of
request `a1185197-8934-4873-a9e9-9cf4dfa6e835` restored source `69b96e54` at
generation 8, retaining dataset GUID `17352425563408051899`. Restoration completed
at 05:33:03.104809; source and destination revocations completed at
05:33:04.319393 and 05:33:04.328219; snapshot pruning at 05:33:09.585586;
slot release at 05:33:09.620392; clone completion at 05:33:09.622369.
Published destination `60bb2b25` retained generation 2, GUID `533972745605228960`,
its original 04:15:20 boot and process. Native snapshot absence, zero held slots,
unchanged guest hashes and exact retry replay were confirmed. No outcomes or
slots were edited directly.

Fresh source `repair-0926-0534` (`b2d3a142-33ee-4977-be89-62d03bfe984d`) was
created with request `04433aab-36b6-489b-b5d8-52b8f5d02dbd`; exact replay and
guest SSH passed. Clone `212f2f83-bf18-41aa-b9fd-c3b5da855ebf`, request
`7e40d52f-983d-4815-992c-a0953e827a12`, initially refused `source_unavailable`.
Supported retry `687a058e-c967-4ecc-96db-ff7f5934f2cc` admitted the same clone
and destination. Source generation 3 then failed at 05:38:08.822 with
`accounting/unconfirmed`, after the import journal was prepared and before its
ordinary destination claim existed. Destination `5b1898a1-2dc9-482e-bff5-6288319ed2d9`
published and ran. Supported retry `e70c8f24-b359-4292-bc60-adb6bafe009b`
restored the source at 05:43:30.915042 and completed cleanup at 05:43:34.607809.
This failure prompted the parent-accounting dependency review; it is not proof
of that exact native predicate at the failure instant.

A second fresh clone, `089f8f69-95df-49f7-aa72-4ede9b8a4638`, request
`01b5d222-572c-4019-adfd-9037830c61c9`, published destination
`ceb0e413-600a-44e2-a769-91476e3ba900` at 05:45:21.021815, restored the source
automatically at 05:45:28.847049 and completed at 05:45:32.568474. Read-only
sampling under the pool lock observed exact private journal/native ownership and
successful deferral during receive. Sampling can alter timing; this is not an
untouched reproduction of the preceding failure. Fixtures with failed histories
remain retained; subsequent transfer and cleanup results are recorded separately.

### Parent-accounting deployment and renewed acceptance

Commit `c729fbeb9f41f374bc81012931f37f77fe4e8f2a` was pushed at 08:35 UTC. Both
hosts activated it through the normal updater: by 08:45 UTC Overalls ran
`/nix/store/y6c5xr2vpy9b0w8jbr9q2qv0xrv0xwv7-nixos-system-overalls-26.05.20260914.c3eea5b`
and Dungarees ran
`/nix/store/s19hfnnwvvdzh3i4pqc6n64i4k59cjyx-nixos-system-dungarees-26.05.20260914.c3eea5b`,
each reporting phase `healthy` with `lastHealthy.revision` matching the commit.
The advertised image catalog had rotated; the successor image
`sha256:14bb5f0382db86c7df570f313618cda7eeb672faa8a51c9782f44fbf2568166d`
replaced the earlier acceptance image with the same disk minimum.

Renewed acceptance on that revision:

| Scenario | Request identity | Observed result |
| --- | --- | --- |
| Fresh creation | `4ebdd95a-30cc-409e-93ec-ddc22e05ea00` | Source `repair3-0926` (`6795cc54-3233-4f41-b696-e0d86352da33`) running; operation `ab74ef8e-ce4c-4c0d-a5dc-5a45e59366ec` |
| Exact creation replay | same request identity | Identical operation and VM receipt |
| Guest SSH and content | source guest | Marker `r3-1790413166` written and read |
| Clone | `46a53981-3345-4264-9101-9bf7b9f30d60` | Clone `7f595f3e-0bb9-4c84-8cab-d7066fc5a31c` ran to `complete` in 73 seconds with no source failure: destination `20274c7f-8e25-4f73-9bc0-80969bb613aa` published 09:00:35Z, source restored 09:00:42Z |
| Exact clone replay | same request identity | Identical operation and destination receipt |
| Guest independence | both guests | Clone carried the pre-clone marker; post-clone writes stayed invisible in the opposite direction |
| Relocation out | `419345f8-a9a6-46e8-80e5-160816914855` | Operation `2514d253-cf53-4824-898d-a4cc3e8a2d51` completed with 88-second downtime; `source_cleanup` and destination settlement finished without refusal |
| Exact relocation replay | same request identity | Identical operation receipt |
| Relocation back | `98ec5f53-8ecf-4bf5-aa2f-7040deb1c4d0` | Operation `cefd4d4b-95ac-4188-acab-63c7d9c9610c` completed with 37-second downtime; guest content intact after each move |
| Same-source race at 09:11:33Z | clone `a1bf195f-ec15-450d-b9d5-4ca5ec2b67e8`; relocation `e9ca6536-821f-4e3c-ac45-6f2373d1fa50` | Clone refused `vm_busy` in 0.27 seconds with no destination VM row materialized; relocation completed |
| Opposite-direction race | relocation `27b495f7-47f7-4765-ace2-0e21bdc69535`; relocation `2ba84c72-2015-43e7-a637-bdee75d47d90` | One refused `transfer_busy` with no durable receipt (a later `request retry` returned `not_found` and a fresh request succeeded); the other completed |
| Successful-fixture cleanup | `rm` on `repair3-copy-0926`, `repair3-0926`, `repair-observed-0926`, `recovery-racecopy-0926` | All four reported `deleted`; read-only SQL showed desired/observed `deleted`, zero unreleased transfer slots and no residual `zroot/lilly` datasets on either host |

Failed-history fixtures `recovery-0926-0351`, `recovery-copy-0926-0351`,
`repair-0926-0534` and `repair-copy-0926-0536` remain running and untouched.
Read-only inspection found the older source `test`, its published destination
`hello` and the 2026-09-25 retained failure fixture `55df4998-77cf-4d51-a2a6-ee089d4393e3`
all absent before this run touched production; this work neither created nor
removed them. Concurrent `vm-57e0/8b35/e1b9` fixtures belong to other in-flight
verification and were not touched. One polling attempt met a transient
`transport_error`; direct status reads recovered the same receipt without
resubmission.

## Final review and remaining gaps

The implementation preserves the accepted placement, execution, storage and
cleanup contracts. Full component gates, native cloning-fleet, updater activation,
supported fresh-clone recovery and both production relocation directions passed
for the first repair. The additional owned-staging boundary repair passed its
full component and native `zfs-guest` gates, deployed to both hosts through the
normal updater, and completed renewed production acceptance: clean automatic
cloning, exact request replays, guest independence, both relocation directions,
same-source and opposite-direction busy refusals with winning transfers
completing, and verified successful-fixture cleanup. The original disappeared
clone cannot be claimed recovered or preserved. Independent power-loss
durability and every image/profile/failure permutation remain outside this
focused recovery scope.
