# backup-recovery-manifest-reference-closure

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
`Always(each retained completed host manifest references existing successful
component snapshots; incomplete/interrupted runs cannot evict that closure)`;
message **"Backup retention recovery preserves the complete reference closure of retained recovery points"**.

Evidence: `nix/domains/system/backups/runtime.py:122-225` captures every required
inventoried guest (flush unconfirmed is degraded, not skipped), PostgreSQL when
configured and host state; records failures and cleanup before complete manifest.
`nix/domains/system/backups/restic.py:213-254` (`manifest`) validates complete structure;
`:256-295` (`retain`) validates retained references before any forget, unioning
shared component IDs. Backup CONTRACTS and ADR-0070 claim short-retention recovery,
not a single cross-service simultaneous point-in-time snapshot.

History: take known good recovery points; interrupt guest/database/host upload,
manifest upload, journal receipt and retention batches. Restart/retry with failed
component or repository listing, retain manifests sharing a component, insert
missing/corrupt manifest reference control, and retry prune. A manifest upload
may commit before its local ACK; list repository to reconcile instead of assuming
absence. Failed new capture must not count as a completed point for keep_last.

Oracle: independent restic repository enumeration and dump of exact manifest IDs,
graph reachability and actual component restore/read-check to owned scratch paths.
Every retained reference exists and restores expected fixture bytes/schema.
Host manifests complete only with all required captured components, not just a
nonempty list. Do not assert recovered PostgreSQL and guest bytes represent one
global instant; sequential capture is documented.

Guidance: `Reachable` **"Backup retention retained a component shared by two completed manifests"**;
**"Backup recovery found an uploaded manifest after its local completion reply was lost"**;
**"Backup retention refused all forgetting when a retained reference was unavailable"**.
Branch markers around repository snapshot effect versus reply and pre-forget
reference validation are more useful than backup-command completion.

Values: keep_last 1/2/3 valid config; completed points K-1/K/K+1; 0/1/2 configured
guests including stopped/flush-unconfirmed; configured/unconfigured PostgreSQL;
shared references; orphan age below/equal/above 86400 seconds, forget batch
127/128/129 IDs. Hosted real restic/file repository covers graph and reply loss;
TCG/native ZFS and real PostgreSQL restore validate actual recovery content.

Open questions: Which declared user-facing restore consistency/RPO target should
govern a later cross-component restore campaign? `(partial: sequential capture
and manifest closure are explicit; no global snapshot/RPO guarantee found)`

### Investigation Log

#### What cross-component restore consistency target is established?

Examined runtime capture order, Restic.manifest/retain and ADR-0070 decision.
Found sequential component capture, complete host graph, retained component
checks and short retention. Not found simultaneous guest/database snapshot or
numeric RPO promise. Conclusion: test closure/content here; do not invent global
transaction consistency or tag human input required without further policy research.
