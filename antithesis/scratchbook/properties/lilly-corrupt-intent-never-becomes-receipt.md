# lilly-corrupt-intent-never-becomes-receipt

P0; high confidence; safety. Planned SDK callsites are **missing** per the [fresh scan](../existing-assertions.md). Proposed `AlwaysOrUnreachable` message: **"Lilly refuses receipt when stored placement intent is unreadable"**. If an owned placement's durable command file or host binding is malformed, differently bound, wrong-versioned or unsafe to read, no successful receipt for a newly delivered command may be emitted until a valid durable command is re-established under the real host lock. A corruption encounter may be absent from a normal run; every encounter must satisfy the refusal, hence `AlwaysOrUnreachable`. The oracle does not treat transient file read errors or timeout as proof that the old intent disappeared.

Source: `lilly/lib/lilly/control/store.ex:11-25` binds existing host/version identity, `:29-54` reads before accepting and rejects conflicts, `:71-119` validates file type, schema, version, placement and host across single/all reads, and `:140-150` publishes accepted commands. `lilly/lib/lilly/host/private_files.ex:19-39,40-63` rejects unsafe files and syncs file plus directory before success. `lilly/lib/lilly/control/runtime.ex:865` documents reread before receipt, and the runtime holds the OS lock while using Store per Store moduledoc. ADR-0017/0037 and `lilly/CONTRACTS` establish the intended execution boundary.

History and independent oracle: start a real supervised Lilly host owner with a valid placement intent and record its raw file hash and authenticated control exchange ID. With the owner stopped or a controlled disk fault at an allowed boundary, replace the command file with truncated JSON, version mismatch, wrong placement/host, symlink, multiple hardlinks or incorrect permissions; restart under the real lock and deliver a higher valid command. Observe wire receipts from a separate Control peer and compare raw file bytes, stat metadata, and host-owned execution attempt records. No new successful receipt can be justified by the corrupted file. Recovery may permanently refuse until operator repair; the property requires safety, not automatic progress. Mutating the file while Lilly holds its lock would violate the workload's ownership precondition and is excluded.

SUT guidance: `Reachable` **"Lilly detected an invalid stored placement command"** at `Store.read/2` rejection is a coverage anchor. `Reachable` **"Lilly replayed durable command after owner restart"** on a separately valid file confirms a positive recovery path. Keep proposed SDK metadata to host, placement, epoch/generation and closed reason; no command payload or credentials. Do not interpret a successful receipt for a *different*, healthy placement as a violation.

Value menu: valid/corrupt file; corruption kind truncated/version/host/placement/mode/link; file lengths 0/1/16384/16385; epoch,generation (1,1),(1,2),(2,1); delivery duplicate 1/2/8; owner restart before/after durable write. Hosted real Lilly Store/Runtime/lock and filesystem suffice for refusal; TCG guest or native host is needed to prove physical effect absence, with real supervision retained. No KVM/isolation claim follows from hosted evidence.

Open questions: None.

Answer: There is no per-command wire refusal in the current exchange: receive_commands halts and fences Runtime with command_store_failed, so the independent peer observes lack of ACK with Runtime phase fenced; socket closure is not a guaranteed response, and no positive corrupt-file response is sent. Existing intent corruption must be seeded after stopping the owning Runtime and releasing its host lock, before supervised restart; never modify a file while live ownership holds.

### Investigation Log

#### Which exchange exposes corrupt existing placement refusal?

- Examined: `lilly/lib/lilly/control/store.ex:36-54,71-119` and runtime's `durable intent` reread contract at `runtime.ex:865`.
- Found: Store returns an error for invalid stored command rather than treating it as absence.
- Not found: exact wire reason mapping from Runtime to Control response in this pass.
- Conclusion: open source-resolvable question; capture raw response and file snapshot before final SDK placement.

#### Can corruption be seeded without bypassing ownership?

- Examined: `Store` moduledoc and `PrivateFiles.write/3` publication.
- Found: Store use assumes host OS lock; private publication can have uncertain result after rename.
- Not found: an existing harness-only fault seam or paused-owner fixture.
- Conclusion: seed corruption only after owner shutdown and before restart, or through a real storage fault; never mutate beneath live lock ownership.

#### Which Runtime exchange response exposes existing-placement corruption?

- Examined: `lilly/lib/lilly/control/runtime.ex:863-915,565-573,791-815; lilly/lib/lilly/control/store.ex:29-54,71-119; lilly/lib/lilly/host/lock.ex:41-113`.
- Found: There is no per-command wire refusal in the current exchange: receive_commands halts and fences Runtime with command_store_failed, so the independent peer observes lack of ACK with Runtime phase fenced; socket closure is not a guaranteed response, and no positive corrupt-file response is sent. Existing intent corruption must be seeded after stopping the owning Runtime and releasing its host lock, before supervised restart; never modify a file while live ownership holds.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: resolved; Remove both questions; correct expected response to local fence/no ACK and describe stop/restart seeding.

#### What owner pause/stop seam permits corruption seeding without violating lock custody?

- Examined: `lilly/lib/lilly/control/runtime.ex:149-170,791-815`, `lilly/lib/lilly/host/lock.ex:41-113`, and `lilly/lib/lilly/control/store.ex:29-54`.
- Found: stop the owning Runtime, wait for host helper release, then alter the owned placement file before supervised restart. A live-owner file mutation would violate the workload precondition.
- Not established: no pause inside a live owned write is required for this corruption case; no native fault run was performed.
- Conclusion: resolved as an owner-stop/restart seam.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger; current measured ZFS pool required for accepted placement. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R2`: The focused command must also emit a distinct `Reachable` at the actual incompatible/corrupt/restart/negative-status danger branch. Optional-path safety can pass without that branch; positive compatible traffic is insufficient. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
