# ziggy-interrupted-inference-never-reexecutes

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../existing-assertions.md).
`Always(recovery/reporter replay causes zero additional provider requests for the
original admitted request; unfinished admission remains interrupted/unknown)`;
message **"Ziggy recovery replays accounting without repeating an inference effect"**.
Explicit new user requests have distinct identities and are outside this count.

Evidence: `ziggy/lib/ziggy/spool.ex:87-117` reserves a durable 16,384-byte slot
before effect; `:201-217`, `:240-253` recovery fills unfinished entries with
interrupted, tokens {}, completeness unknown and duration/byte counts nil;
`:260-285` persistence failure fences admission. `ziggy/lib/ziggy/http.ex:347`
starts upstream only after admission (`:414`); `ziggy/lib/ziggy/agent_worker.ex:86-125`
has a separate model effect path. `ziggy/lib/ziggy/reporter.ex:38-53` reports
completed metadata. Ziggy CONTRACTS prohibit replaying inference or treating
missing usage as zero. Check HTTP and agent paths independently.

History: kill request owner/release after durable admission, before upstream,
after upstream accepted prompt, midway through stream, after completion publish
but before ACK. Restart actual Ziggy/spool; keep upstream effects in an independent
durable witness. Cause reporter/Marshall outage and ACK loss, then restore.

Oracle: upstream fixture durable effect ledger keyed by workload correlation
without exposing prompts to diagnostics; decode spool and committed Marshall
request/completion. Observe zero *recovery-originated* duplicate upstream effects
and unknown usage for unproven completions. SDK queue admission is not the
admission proof. Spool errors can leave published old/new entries uncertain;
failed admission must prevent the corresponding provider effect.

Guidance: `Reachable` **"Ziggy recovered an admission after an independently witnessed provider effect"**
at recovered interrupted entry with witness; **"Ziggy fenced provider admission after uncertain spool publication"**
at failed store plus refusal. Place safe phase/revision markers around durable
slot, lease, upstream acceptance, completion rename and reporter ACK.

Values: max_requests 1/2/8 (valid constructor values), occupy 0/N-1/N slots,
stream fragments 0/1/8, malformed/full/unavailable storage, 1/2/8 replay reports.
Real services and local provider fixture work hosted; this establishes proxy
behavior against the fixture, not provider-side exactly-once semantics outside
the repository. No credential/prompt/response bytes enter assertion metadata.

Open question: Can the selected hosted fixture preserve a private, durable effect ledger across Ziggy and fixture restarts for concurrent HTTP and agent calls? The current packaged fixture counts accepted provider calls, but does not tie every concurrent call to a Ziggy admission ID.

### Investigation Log

#### Which safe fixture correlation can witness HTTP and agent provider effects without changing their production request payload semantics?

- Examined: `ziggy/lib/ziggy/upstream.ex:20-80`, `ziggy/lib/ziggy/http.ex:323-420`, `ziggy/lib/ziggy/agent_worker.ex:68-130`, `ziggy/lib/ziggy/config.ex:34-38`, `nix/tests/machines/ziggy-service/default.nix:4-18,94-100`, and `driver.py:135-190`.
- Found: Ziggy generates an internal request ID and passes it to the local spool/diagnostic event, but `Upstream.stream/5` does not forward that ID to the provider. The packaged Nix fixture maps fixed provider hostnames to a local TLS server and counts accepted provider calls; it also exercises one agent claim and one killed unfinished HTTP stream without provider replay. The OpenAI-compatible Underclass loopback is a separately validated origin option; request input cannot select an arbitrary origin.
- Conclusion: resolved for a single controlled outstanding call: use a unique synthetic payload marker already legal in the ordinary request body, let only one matching HTTP call or one agent claim run in that window, and count provider fixture accepts before/after recovery. Keep the marker in the private fixture ledger only, never in Ziggy diagnostics. For concurrent calls, add a private fixture-side correlation ledger or keep histories serialized; provider-side exactly-once outside the fixture is not established.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-satellite`. proposed-real-inner-zfs-backed-current-VM-plus-satellite; unbuilt; independent witness: durable Ziggy spool ID, independent provider accept log and Marshall aggregate; current real placement/execution authority required. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
