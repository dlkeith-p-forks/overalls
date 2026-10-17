# brady-cache-complete-publication

P1; high confidence; safety. Planned Antithesis assertion is **missing** per the [fresh scan](../../existing-assertions.md). Proposed `Always` message: **"Brady cache hit serves a complete committed object"**. Whenever the cache serves a hit for a controlled object, the returned body and eligible metadata match a complete upstream response that the workload observed before publication; aborted or incomplete writes never become hits. This is checked on every hit and so uses `Always`. The guarantee concerns process/power interruption of cache publication under owned storage, not arbitrary same-length bit rot in the disk media (no checksum is stored).

Source: `brady/lib/brady/cache/store.ex:245-296` requires exact declared length or confirmed chunk termination, data sync/close, metadata write, and atomic directory rename before indexing. `:306-329` opens only a valid indexed object with correct body length; `:592-645` recovery validates directory/name/metadata/body length before adopting published objects. `:333-350` reads lease-owned bytes. `brady/lib/brady/proxy.ex:124` identifies hit serving. The source contract states intended behavior, not passing evidence.

History and independent oracle: a local origin fixture emits unique deterministic body bytes, content length, ETag and cache-safe headers, and stores the origin version/hash in an append-only workload ledger. A client records full response bytes and a separate cache hit signal. Cut Brady after each chunk, after body sync, after metadata write, around rename, and before/after restart recovery. Repeat with declared length one byte short/long and valid chunk termination. A miss or bypass after uncertain write is allowed; any hit must equal a fully completed origin version, including content and permitted metadata. Confirm the origin did not change during comparison and use a fresh key per history. Do not infer durability from cache hit counts alone.

SUT guidance: `Reachable` **"Brady recovered a published cache object after restart"** in `recover_entry/3` on a validated entry; `Reachable` **"Brady refused an incomplete cache commit"** on the failed commit branch. Both are useful coverage anchors, not failures. A `AlwaysOrUnreachable` **"Brady recovery indexes only validated complete object directories"** at the rare recovery adoption path is appropriate because a run with no recovered objects need not fail. Avoid putting body bytes into SDK metadata or logs.

Value menu: declared bytes 0/1/chunk-1/chunk/chunk+1/configured object limit; chunked termination valid/abrupt; concurrent leases 1/max-1/max; storage budget exact fit/one byte short; cut points listed above. Hosted real Brady plus local filesystem and origin exercise publication; a TCG storage VM can add actual power-cut ordering, while native ZFS/physical durability requires native execution and cannot be inferred from hosted files. Cache eviction is allowed and not a loss of business state.

Open questions: Which external response header or event proves a cache hit without asking Brady's store to self-attest? Can the hosted filesystem/fault setup offer a true persisted power-cut boundary, or only process kills?

### Investigation Log

#### Which signal proves a hit independently?

- Examined: `brady/lib/brady/proxy.ex:124` and `brady/lib/brady/cache/store.ex:306-350`.
- Found: proxy records `cache: :hit` after store open/read, while origin fixture can count requests independently.
- Not found: proof that a response header exposes hit/miss to the client.
- Conclusion: use origin request count plus distinct response bytes and a separately observed proxy event; validate the exact event shape when implementing.

#### Does hosted execution permit a power-cut boundary?

- Examined: [SUT environment analysis](../../sut-analysis.md#antithesis-environments-and-independent-oracles).
- Found: hosted real files and TCG storage are separate scopes.
- Not found: a configured hosted power-loss injector for the cache mount.
- Conclusion: claim hosted process-cut evidence only until TCG or native storage run records actual power interruption.
