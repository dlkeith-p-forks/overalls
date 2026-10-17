# marshall-admission-key-survives-archive

P0; high confidence; safety. Proposed SDK assertion **missing** in the [fresh existing-assertions scan](../existing-assertions.md). `Always` **"Marshall replayed admission key never allocates a second VM"**: for each owner/key, successful identical retries return the original VM ID even after physical deletion archives it; a changed request shape returns idempotency conflict and does not allocate. `Always` fits every settled retry result. A timed-out first call is an uncertain attempt and must be reconciled by history, not presumed failed.

Source: `marshall/lib/marshall/compute/admission.ex:34-85` locks owner/key before history lookup and compares name/team/source and architecture/image/profile/size; `:112-119` reads stored source. `marshall/lib/marshall/compute/virtual_machine.ex:1-4,28-30,453-455` preserves archived history and owner/key identity. `marshall/lib/marshall/compute/ledger.ex:113-119` exposes history read. ADR-0010's inherited idempotency requirements through ADR-0050 and the lost-reply review are design/recorded historical evidence, not a passing Antithesis result.

History and independent oracle: an authenticated machine LiveView form passes its `request_key` into Compute admission, while an SSH `request-id` pins an outer SSH receipt and generates a separate internal Compute key. A workload should send one stable LiveView key/shape, cut response after DB commit, retry through a second Marshall node, then drive real deletion and physical cleanup to archive. Replay identical and changed shapes through that form, or use SSH only when checking its separate receipt-level idempotency. Observer retains attempted request envelopes and acknowledged VM IDs, plus a separate consistent PostgreSQL history query including archived rows and placements. Check count of distinct VM IDs for the owner/key is one; check no new allocation/operation after changed retry. A permanent refusal for an archived VM's unrelated current availability is not proof of duplicate allocation; inspect DB identity.

Branch guidance: `Reachable` **"Marshall admission replay found archived idempotency history"** at `Admission.run/3` history-hit branch when archived; `Reachable` **"Marshall admission rejected changed same-key request"** at `:76`. These are positive replay/refusal anchors, not violation assertions. Safe metadata: owner, key hash, VM ID and closed reason; never source reference or SSH material.

Value menu: callers 1/2/8; same key and same/different name/team/image/profile/size/source; first reply delivered/dropped; active/deleted/archived original; one/two/three Marshall nodes; 0/1/2 eligible hosts. Hosted real Marshall/PostgreSQL/Oban covers durable identity; real TCG/native guest is needed only to reach actual physical cleanup/archival. Do not simulate archival with direct row mutation.

Open questions: Can a hosted TCG fixture complete the native physical cleanup and archival path without direct row mutation? `(partial: the current native fleet lifecycle scenario does so; hosted TCG deletion wiring is unbuilt)`

### Investigation Log

#### Which public endpoint preserves the key?

- Examined in the follow-up: `marshall/lib/marshall/ssh/commands.ex:86-132,274-322`, `marshall/lib/marshall_web/live/machines_live.ex:113-134`, `marshall/lib/marshall_web/live/launch_live.ex:45-66`.
- Found: the SSH command accepts caller `request-id` as an outer durable `SSH.Request` key, but passes a newly generated UUID into `Compute.provision` on the first execution. SSH replay hits the pinned receipt before Compute. The authenticated LiveView machine form forwards its `request_key` directly to Compute. Repository launch derives actor/source/visit key rather than accepting an arbitrary caller key. No generic HTTP JSON admission route was found in the inspected public wrappers.
- Conclusion: resolved with a crucial distinction. Use the authenticated machine LiveView form to exercise a caller-supplied Compute admission key; an SSH retry establishes its separate receipt contract and cannot alone prove Compute key survival through archive. A direct domain test can isolate the Compute invariant.

#### How does the test reach archived state?

- Examined in the follow-up: `nix/verification/tests/machines/fleet/scenarios/lifecycle.py:41-100` and `nix/verification/tests/machines/fleet/scenarios/capacity.py:227-248`.
- Found: the native fleet driver issues real lifecycle stop/delete, waits for `compute_virtual_machines.archived_at`, requires held compute/disk flags false, absence of systemd VM service and ZFS dataset/rootfs, then checks the pool allocation disappears. It does not mutate `archived_at` directly.
- Not found: a built hosted TCG deletion fixture and a combined native test that replays the original admission key *after* this cleanup. Native test structure is not a passing Antithesis result.
- Conclusion: partial for the hosted plan. Compose the public SSH replay around this native cleanup sequence or build equivalent TCG physical deletion; only then assert the archived-key behavior end to end.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: caller key/committed rows correlated with exact physical boot, disk or capacity sample; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R14`: Accepted placement requires a real current measured inner-ZFS-backed Lilly pool and execution readiness, or native KVM. The current Control-only hosted pool reports unavailable and cannot establish admission, guest or satellite effects; never seed fake admission. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/admission/scenarios.py:244`. Observed first-key SQL contradictions fail, identical replay and exact idempotency conflict are checked, and archived replay waits for real delete plus SQL archival; integrated physical cleanup and hosted execution remain unverified. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
