# lilly-receipt-survives-control-loss

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
`Always(acknowledged_command has matching-or-newer host-bound durable intent after reopen)`;
message **"Lilly command receipt remains backed by matching durable intent after restart"**.
This is a delivery guarantee, never proof of physical completion or released capacity.

Evidence: `lilly/lib/lilly/control/runtime.ex:863-914` (`receive_commands/2`)
queues ACK only after Store.read verifies matching/newer intent and known pool;
`lilly/lib/lilly/control/store.ex:11-29` defines host identity/revision format.
`lilly/lib/lilly/host/private_files.ex:36-58` (`write/3`) syncs file, rename and
directory before success; errors explicitly leave publication uncertain.
Directory CONTRACTS and ADR-0013/0016/0017 prohibit treating receipt as lifecycle authority.

History: take ACK immediately before network disconnect or release kill; restart
with same bound state; replay identical command while newer command arrives.
Inject file write, rename and directory sync failure separately. Track attempted,
acknowledged and committed commands separately; an unacknowledged attempt may
nevertheless have been published, so do not assert rollback on error.

Oracle: outside SUT, retain transmitted command/ACK identities; reopen Store and
decode actual private bytes under its real owner lock. Compare host/VM/placement,
ordered epoch/generation and immutable command fields, plus PostgreSQL authority.
Reject corrupt identity rather than synthesizing empty state. No aggregate suite
exit or log event is the oracle.

Branch guidance: `Reachable` **"Lilly recovered a command whose receipt channel was lost"**
after reconnect reread; `AlwaysOrUnreachable` **"Lilly uncertain state publication fences receipt acknowledgment"**
only in the storage-error branch, checking no new ACK before valid recovery.
Always is the primary property because ACKs are required baseline coverage;
storage-error path may be unavailable in a particular container campaign.

Values: 1/2/8 commands, equal/older/newer epoch pairs, duplicate batches, state
storage full/available and sync interruptions; valid/unknown pool control. Real
BEAM/Control/files/locks hosted environment can establish this local durability
boundary; power-loss durability depends on actual filesystem fault support and
must be recorded separately. No physical guest guarantee follows.

Open questions: Which hosted filesystem faults actually model directory fsync
loss rather than only injected process death?
