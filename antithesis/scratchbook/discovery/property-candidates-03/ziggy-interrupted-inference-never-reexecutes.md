# ziggy-interrupted-inference-never-reexecutes

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
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

Open questions: Which safe fixture correlation can witness HTTP and agent
provider effects without changing their production request payload semantics?
