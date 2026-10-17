# lilly-corrupt-intent-never-becomes-receipt

P0; high confidence; safety. Planned SDK callsites are **missing** per the [fresh scan](../../existing-assertions.md). Proposed `AlwaysOrUnreachable` message: **"Lilly refuses receipt when stored placement intent is unreadable"**. If an owned placement's durable command file or host binding is malformed, differently bound, wrong-versioned or unsafe to read, no successful receipt for a newly delivered command may be emitted until a valid durable command is re-established under the real host lock. A corruption encounter may be absent from a normal run; every encounter must satisfy the refusal, hence `AlwaysOrUnreachable`. The oracle does not treat transient file read errors or timeout as proof that the old intent disappeared.

Source: `lilly/lib/lilly/control/store.ex:11-25` binds existing host/version identity, `:29-54` reads before accepting and rejects conflicts, `:71-119` validates file type, schema, version, placement and host across single/all reads, and `:140-150` publishes accepted commands. `lilly/lib/lilly/host/private_files.ex:19-39,40-63` rejects unsafe files and syncs file plus directory before success. `lilly/lib/lilly/control/runtime.ex:865` documents reread before receipt, and the runtime holds the OS lock while using Store per Store moduledoc. ADR-0017/0037 and `lilly/CONTRACTS` establish the intended execution boundary.

History and independent oracle: start a real supervised Lilly host owner with a valid placement intent and record its raw file hash and authenticated control exchange ID. With the owner stopped or a controlled disk fault at an allowed boundary, replace the command file with truncated JSON, version mismatch, wrong placement/host, symlink, multiple hardlinks or incorrect permissions; restart under the real lock and deliver a higher valid command. Observe wire receipts from a separate Control peer and compare raw file bytes, stat metadata, and host-owned execution attempt records. No new successful receipt can be justified by the corrupted file. Recovery may permanently refuse until operator repair; the property requires safety, not automatic progress. Mutating the file while Lilly holds its lock would violate the workload's ownership precondition and is excluded.

SUT guidance: `Reachable` **"Lilly detected an invalid stored placement command"** at `Store.read/2` rejection is a coverage anchor. `Reachable` **"Lilly replayed durable command after owner restart"** on a separately valid file confirms a positive recovery path. Keep proposed SDK metadata to host, placement, epoch/generation and closed reason; no command payload or credentials. Do not interpret a successful receipt for a *different*, healthy placement as a violation.

Value menu: valid/corrupt file; corruption kind truncated/version/host/placement/mode/link; file lengths 0/1/16384/16385; epoch,generation (1,1),(1,2),(2,1); delivery duplicate 1/2/8; owner restart before/after durable write. Hosted real Lilly Store/Runtime/lock and filesystem suffice for refusal; TCG guest or native host is needed to prove physical effect absence, with real supervision retained. No KVM/isolation claim follows from hosted evidence.

Open questions: Which runtime exchange response exposes the refusal for a corrupt *existing* placement, and can the harness pause the host owner at an allowed boundary to seed corruption without bypassing custody?

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
