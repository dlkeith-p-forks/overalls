# lilly-receipt-survives-control-loss

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../existing-assertions.md).
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

Open questions:

- Which hosted filesystem faults exercise directory fsync uncertainty? `(partial: process fault differs from directory sync power-loss fault)`

Next probe: PrivateFiles.write syncs the temporary file, renames it, then invokes sync on the containing directory before success. A process kill only exercises control/process loss; it does not model loss of a successfully acknowledged directory sync. Probe an owned block-backed filesystem with power-cut or fault injection around rename/sync, retaining raw image and ACK transcript, before claiming directory durability under crash.

### Investigation Log

#### Which hosted filesystem faults exercise directory fsync uncertainty?

- Examined: `lilly/lib/lilly/host/private_files.ex:36-58,65-90; lilly/lib/lilly/control/runtime.ex:863-914; antithesis/scratchbook/emulated-storage-feasibility.md`.
- Found: PrivateFiles.write syncs the temporary file, renames it, then invokes sync on the containing directory before success. A process kill only exercises control/process loss; it does not model loss of a successfully acknowledged directory sync. Probe an owned block-backed filesystem with power-cut or fault injection around rename/sync, retaining raw image and ACK transcript, before claiming directory durability under crash.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: partial; Retain partial for real fsync/power-loss fault; scope hosted process faults precisely.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger; current measured ZFS pool required for accepted placement. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
