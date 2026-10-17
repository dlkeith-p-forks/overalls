# inference-accounting-ack-loss-counted-once

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
`Always(one retained immutable completion contributes once to lifetime totals,
and conflicting/foreign completion contributes zero)`; message
**"Inference accounting recovery counts each immutable completion once despite lost acknowledgments"**.

Evidence: `marshall/lib/marshall/inference/requests.ex:121-156` (`complete/3`)
authenticates host, locks Request, acknowledges identical accounting projection,
rolls back conflicting completion, updates receipt and `Totals.add!` in one
Ledger transaction. `ziggy/lib/ziggy/spool.ex:172-197` removes only completed slot
after ACK and durable local SLO count; `ziggy/lib/ziggy/reporter.ex:38-53` sends
retained completion. Completion does not renew current execution authority and
is allowed after the original VM stops/relocates with valid admitted-host custody.

History: actual provider completes; Marshall commits completion and totals, socket
loses response; restart either release and retransmit many times. Interrupt local
slot removal/directory sync; replay under current host credential, foreign host,
same body, changed accounting body and post-VM-stop histories. Keep the same
request identity for actual replay, not generated new IDs.

Oracle: externally modeled sum of unique accepted accounting projections, compared
to committed Request rows and Totals for exact owner/provider/model grouping.
Unknown fields/tokens remain unknown; do not coerce missing numbers to zero in
the expected model. External provider effects are separately checked by the
interrupted-inference candidate. ACKed spool removal is local custody, not proof
that the stream consumer received a response.

Guidance: `Reachable` **"Marshall acknowledged a retained inference completion after its earlier commit reply was lost"**
at duplicate projection branch with observer commit history; **"Ziggy removed a recovered completion only after matching accounting acknowledgment"**
after durable ACK cleanup. Put assertion after outer transaction commit, following
reviewed Events catalog requirements for any diagnostic events.

Values: 1/2/8/128 duplicates, completion present/absent/conflicting, known/partial/
unknown usage, original/current/foreign host, report batch boundaries 1/127/128.
Hosted real PostgreSQL/BEAM/Control/spool with independent upstream ledger suffices
for accounting transaction behavior; no VM isolation claim follows.

Open questions: None for intended semantics; current passing execution and SDK
installation remain missing.
