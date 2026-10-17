# Database durability, promotion and isolated restoration

## Scope and evidence

Implement the application durability setting and a provider-neutral local
acceptance harness for the database recovery obligations under ADR-0003/ADR-0027.
[ADR-0029](../decisions/0029-database-durability-and-recovery.md) records the
acknowledgment, fencing and historical-restore quarantine boundaries. The user's
full implementation authorization covers these requirements; production provider
selection remains open.

The [harness](../../../nix/verification/tests/README.md) uses actual PostgreSQL,
TLS replication, three immutable Marshall releases and the shared
[deployment fixture](../../../nix/verification/tests/README.md). It does not simulate
physical VM state or claim that test records establish guest recovery.

## Findings and changes

### High: role defaults could weaken durable acknowledgment — fixed

[Runtime configuration](../../../marshall/lib/marshall/operations/runtime_config.ex)
previously inherited `synchronous_commit`. A database role configured with `off`
could acknowledge a command before durable storage despite successful application
transactions. Connections now explicitly request `on`. The provider still owns
the synchronous standby policy, durable storage and safe election/fencing.

### High: historical restore may resurrect revoked authority — required work

The acceptance fixture backs up one credential, revokes it in the live cluster,
then restores and decrypts the older credential in a separate read-only database.
This makes the recovery boundary concrete: successful database restoration is
insufficient to authorize connection to surviving guests. Serving nodes and jobs
remain absent from the restored fixture. Automated fleet reconciliation, authority
renewal and protection against stale physical commands remain unimplemented;
ADR-0029 is partial and the recovery guide explicitly prohibits live reuse.

### Infrastructure limits remain explicit

The test controls local processes and routing. It confirms old-primary shutdown,
then promotes and rebuilds a synchronous standby before reconnecting the existing
Marshall services. This does not implement automatic failure detection, election,
infrastructure fencing, off-host backups or independent failure domains.

### Fixture cleanup ownership — strengthened

The shared acceptance fixture now retains its created directory's device/inode
and a private random identity marker. Cleanup rejects a replaced directory,
missing/changed marker, symlink, hard link, wrong owner or permissive modes before
stopping services or deleting data. All three fixture consumers use the same
verified removal helper. Six filesystem tests exercise successful deletion and
the rejected cases without starting services.

## Contract review

Applicable root, script, domain and operations contracts were discovered and
reviewed. New contracts cover durable connections, fixture scope, private command
diagnostics, acknowledgment waiting, promotion fencing, replacement replication,
backup quarantine and secret-probe behavior. The authenticated GitHub owner is
`ghuntley`; no notification recipients were inferred or messages sent.

The shared fixture's constructor, command runner, service/SQL helpers and cleanup
were inspected along with both existing acceptance consumers. The runtime parser's
production configuration consumer and configuration tests retain verified TLS,
primary-only selection and fixed secret-free error behavior. Native Elixir
semantics require manual review; contract syntax/discovery alone is not proof.

## Verification performed

- PostgreSQL 18.6/HAProxy 3.4.3 acceptance passed using three immutable Marshall
  services and real authenticated TLS replication. The host-table mutation waited
  in PostgreSQL `SyncRep` with its write lock held and its HTTP future incomplete;
  returning the standby allowed that same request to succeed.
- Immediate primary shutdown was confirmed before promotion. A new synchronous
  replica reached `sync` before routing resumed. All three Marshall MainPIDs were
  unchanged and returned the exact acknowledged session identity/epoch. Recovered
  host/session rows and pre-failure credential archival were inspected before any
  API retry could recreate lost state; all three nodes reject that old credential.
- Physical backup verification, deliberate corruption rejection and actual
  read-only restore passed. The isolated restored credential decrypts with the
  preserved keyring and fails with the original cipher identity missing. All live
  nodes reject the credential revoked after the backup. No serving process or
  worker connects to the restored copy.
- Fixture cleanup and generated-secret scans passed. Six ownership tests and
  Python syntax checks passed.
- Marshall `mix precommit`: 218 cases (23 properties, 195 tests), four optional
  host cases excluded; six browser-state checks and nine contract-checker
  regression checks. Compiler/Dialyzer pass with the
  existing one upstream typespec exclusion and no unnecessary exclusions.
- Marshall release rebuilt/exported with Elixir 1.20.4/OTP 29.0.6. The runtime change
  was exercised from that immutable release, not just a development build.
- Contract syntax/discovery passes for the changed declarations and directory
  contracts using cc-check 0.2.0. The final repository-wide structural check also
  passes: 41 contract files, 304 native notes and six supported source documents,
  covering 384 maintained source files. This is not a semantic proof.
- ADR structure and local links pass for all 29 decisions. ADR-0029 remains
  accepted/partial, and ADR-0003/ADR-0027 and the overview retain their explicit
  production infrastructure and historical-recovery limits.

## Remaining work

Select and exercise the production HA provider/controller, backup/key custody,
retention, PITR and authoritative historical-restore reconciliation. Complete
independent-host, physical isolation, real SMTP and fleet workload acceptance.
No production availability or full-plan completion claim follows from this local
recovery milestone.
