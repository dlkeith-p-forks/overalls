# marshall-admission-key-survives-archive

P0; high confidence; safety. Proposed SDK assertion **missing** in the [fresh existing-assertions scan](../../existing-assertions.md). `Always` **"Marshall replayed admission key never allocates a second VM"**: for each owner/key, successful identical retries return the original VM ID even after physical deletion archives it; a changed request shape returns idempotency conflict and does not allocate. `Always` fits every settled retry result. A timed-out first call is an uncertain attempt and must be reconciled by history, not presumed failed.

Source: `marshall/lib/marshall/compute/admission.ex:34-85` locks owner/key before history lookup and compares name/team/source and architecture/image/profile/size; `:112-119` reads stored source. `marshall/lib/marshall/compute/virtual_machine.ex:1-4,28-30,453-455` preserves archived history and owner/key identity. `marshall/lib/marshall/compute/ledger.ex:113-119` exposes history read. ADR-0010's inherited idempotency requirements through ADR-0050 and the lost-reply review are design/recorded historical evidence, not a passing Antithesis result.

History and independent oracle: a real public HTTP or SSH admission client sends one request with workload-owned owner/key/shape, cuts response after DB commit, retries through a second Marshall node, then drives real deletion and physical cleanup to archive. Replay identical and changed shapes. Observer retains attempted request envelopes and acknowledged VM IDs, plus a separate consistent PostgreSQL history query including archived rows and placements. Check count of distinct VM IDs for the owner/key is one; check no new allocation/operation after changed retry. A permanent refusal for an archived VM's unrelated current availability is not proof of duplicate allocation; inspect DB identity.

Branch guidance: `Reachable` **"Marshall admission replay found archived idempotency history"** at `Admission.run/3` history-hit branch when archived; `Reachable` **"Marshall admission rejected changed same-key request"** at `:76`. These are positive replay/refusal anchors, not violation assertions. Safe metadata: owner, key hash, VM ID and closed reason; never source reference or SSH material.

Value menu: callers 1/2/8; same key and same/different name/team/image/profile/size/source; first reply delivered/dropped; active/deleted/archived original; one/two/three Marshall nodes; 0/1/2 eligible hosts. Hosted real Marshall/PostgreSQL/Oban covers durable identity; real TCG/native guest is needed only to reach actual physical cleanup/archival. Do not simulate archival with direct row mutation.

Open questions: Which public admission endpoint preserves the caller-supplied key through SSH and HTTP wrappers? What bounded TCG/native deletion history reaches archived state without bypassing physical cleanup?

### Investigation Log

#### Which public endpoint preserves the key?

- Examined: `compute/admission.ex:44-85` and VM history identity. Found: the action consumes `idempotency_key` and history includes archived rows. Not found: wrapper-level key mapping in this pass. Conclusion: resolve exact HTTP/SSH client route before implementing workload.

#### How does the test reach archived state?

- Examined: `compute/virtual_machine.ex:1-4,28-30`. Found: archival is the physical-deletion terminal identity. Not found: a hosted TCG fixture proving full cleanup in this pass. Conclusion: initial hosted test can exercise active replay; archival claim requires recorded real cleanup path.
