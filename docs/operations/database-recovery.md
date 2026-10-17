# Database durability and recovery

Marshall's durable state must survive promotion without losing acknowledged
transactions. [ADR-0029](../architecture/decisions/0029-database-durability-and-recovery.md)
defines that requirement and distinguishes it from historical backup recovery.

## Production requirements

The release explicitly requests `synchronous_commit=on` for Repo connections,
overriding weaker role defaults. The database operator must configure synchronous
replication, durable storage (`fsync` and `full_page_writes` enabled), eligible
failover candidates and infrastructure fencing. The application setting alone
does not make PostgreSQL highly available.

Configure `DATABASE_URL` to the HA provider's stable writable-primary endpoint,
with verified TLS as described in the [deployment guide](deployment.md). Its
failover controller must exclude or fence the old primary before admitting a
replacement, preserve acknowledged commits and restore required synchronous
redundancy before accepting new writes. A backend becoming reachable is not
evidence that it may become authoritative.

When required replication is unavailable, a request can wait or time out. Reuse
its idempotency key to determine its outcome; cancellation does not establish
rollback. Do not switch the application to asynchronous commits to bypass this
condition. See [PostgreSQL's durability settings](https://www.postgresql.org/docs/18/runtime-config-wal.html)
and [failover requirements](https://www.postgresql.org/docs/18/warm-standby-failover.html).

The production HA provider/controller and independent infrastructure are still
unselected. The fixture below is a recovery test, not a deployment controller.

## Local acceptance

Use the NixOS test catalog for database durability and failover acceptance. The
tests build private machines and databases from the pinned runtime; they do not
use the development database, production credentials or physical guest resources.

It checks:

1. Verified TLS and authenticated streaming replication from a primary to a
   synchronous standby; a role default of `synchronous_commit=off` does not change
   the release's effective connection setting.
2. A real authenticated host-session mutation waits for synchronous replication.
   The test identifies its host-table write lock, verifies the HTTP response has
   not completed, then resumes replication and receives success.
3. Immediate old-primary shutdown, confirmed process termination, standby
   promotion and a new synchronous replica before traffic resumes. The same three
   Marshall processes reconnect through the stable endpoint and retain the exact
   acknowledged host-session response. Recovered session/nonce rows and a
   pre-failure credential revocation are checked before any API retry; all nodes
   still reject the revoked credential afterward.
4. Credential rotation through the operator release command, a physical base
   backup, manifest/WAL verification and rejection of a deliberately corrupted
   version file. A later rotation invalidates the backed-up credential in all
   live nodes.
5. Actual restoration into a separate loopback database with read-only defaults.
   A standalone probe starts only Postgrex and the vault, checks the fixture
   identity and decrypts the older credential using its external keyring. Missing
   key identity fails. No Marshall service, Repo or background worker is started
   against the restored snapshot.

Only replication bootstrap uses local commit acknowledgment while rebuilding a
standby. Application sessions retain synchronous durability. All databases and
services in this test share one physical host; it does not validate storage loss,
network partition election or independent failure domains.

Success removes the fixtures. Failure attempts cleanup and retains private
`/tmp/overalls-deployment-*` diagnostics. A cleanup failure retains the directory
for inspection. Check recorded PostgreSQL directories/PID files and uniquely named
systemd services before manual cleanup; do not apply fixture commands to a live
database. Generated credentials and encryption keys must not be copied into issue
reports or logs.

## Historical restore and key recovery

Keep database backup/WAL archives and the ordered `MARSHALL_CLOAK_KEYS` keyring in
separately controlled, encrypted durable storage. Retain every key needed by the
chosen recovery point, including its cipher identifier. Restore drills must prove
decryption as well as database readability. PostgreSQL backups do not include
host-local VM disks or Lilly journals.

A historical database can contain an active credential that the current database
has already revoked. The local harness demonstrates this explicitly. It can also
contain old host/session epochs, writer claims, login tokens and physical commands.
Never point live provisioners, public endpoints or job workers at a restored copy
just because migrations and health checks pass.

Restore into isolation and inspect read-only. Preserve the original databases,
Lilly journals and physical guest state until an operator can reconcile identities,
generations, reservations and pending work. Reestablish account, credential and
terminal authority before traffic resumes. Unknown physical capacity stays
reserved. A complete automated fleet reconciliation tool is still required; this
repository does not yet support turning a historical restore into live authority.

The [host recovery backup module](backups.md) provides scheduled encrypted S3
backups and short retention, including a logical dump of the database selected
by Marshall's runtime connection string. Its isolated restore test verifies a
usable database. Production endpoint/credential configuration, physical backup
and WAL archival, PITR, key-custody drills and recovery-time targets remain
separate requirements; the logical dump does not establish them.
[Backup verification](https://www.postgresql.org/docs/18/app-pgverifybackup.html)
must be supplemented with actual restore tests.
