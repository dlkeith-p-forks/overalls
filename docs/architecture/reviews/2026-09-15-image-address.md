# Image and address admission review — 2026-09-15

## Scope and evidence

Reviewed new Ash image/address resources, admission lock/rollback boundaries,
host availability reports, local immutable artifact verification, manifest
derivation and migration against staged relocation, existing unstaged work and
new implementation files. Existing application work is preserved.

Architecture impact: ADR-0014 refines ADR-0010 admission and ADR-0011 artifact
metadata; ADR-0005/0007 gain retained address identity. ADR-0012 wire v1 remains
receipt-only. ADR-0013 now includes verified image availability in observations.
Acceptance comes from the existing implementation plan; no new approval gate.

## Findings and decisions

- **Medium, fixed verification defect:** Dialyxir's lockfile-only quick check
  missed new modules in the local protocol dependency, producing unknown-function/
  type warnings. Both consumer precommit aliases now use `--force-check`, the
  documented local-dependency option. No new warning exclusions were introduced.

- **High, documented unimplemented requirement:** v1 commands do not carry image
  or address, and Lilly has no execution driver. Keep execution disabled; add a
  reviewed execution contract, preallocation/mutation coordination, jailer,
  independent supervision and physical reconciliation before user provisioning.
- **High, documented unimplemented requirement:** a database address does not
  establish NAT or guest isolation. Implement and test routing, anti-spoofing,
  private/host destination restrictions and cleanup on two independent KVM hosts.
- **Medium, explicit migration limit:** the new non-null image relationship
  cannot adopt preexisting imageless VM rows. Migration was reviewed/applied to
  the empty-intent development test database; no speculative backfill was added.
- **Medium, deployment obligation:** local hashes establish content integrity,
  not publisher authenticity. Trusted operators/Nix stage read-only artifacts;
  no remote URL fetching exists. The driver must rehash before use and preserve
  the verified copy boundary. File metadata polling alone cannot defend against
  a malicious root operator.
- **Medium, performance evidence pending:** profile serialization, bounded /16
  search, startup hashing and per-sample file checks need workload measurements.
  Three BEAMs/two host records do not establish 100-instance fleet throughput.

No accepted requirement was narrowed. VM lifecycle/recovery, sharing/terminal
leases and revocation, telemetry rollups/retention, deployment/failover and the
second real host remain part of the active platform work.

## Verification

Final precommit gates passed in all three projects:

- Marshall: 63 tests and six properties, including three separate BEAM nodes,
  same-image admission across two host records, duplicate requests and failed-job
  rollback of address/reservation/VM/operation/audit. Four host tests are opt-in.
- Lilly: 24 tests and eight properties; compilation and Dialyzer pass.
- Protocol: five tests and five properties, including an independent compact
  JSON/SHA-256 identity test vector; compilation and Dialyzer pass.
- Marshall Dialyzer passes with the one existing precise upstream
  `Ash.Resource.record/0` exclusion; zero new exclusions and no unused filters.
- Four explicit Linux/ext4/TLS host tests pass, including image disappearance
  with continuing capacity reports. An overlapping Mix process initially caused
  connection-limit diagnostics in the temporary database; the isolated rerun
  passes without those diagnostics. Keep database suites sequential in this setup.
- `mix ash.codegen --check`, the 14-ADR structural/link validator and
  `git diff --check` pass. The migration was reviewed and applied successfully.

Original-file hash comparison found no missing original files and only the
previously intended implementation changes; the 46 staged source relocations
remain unchanged. No commit, deployment or external message was sent.

`devenv build outputs.guest` produced
`/nix/store/3904gg1ik7kdwa6v79949an80z3qz01g-lilly-nixos-x86_64`.
The development loader and rebuilt production Lilly release both verified all
artifact hashes and subsequent availability:
`sha256:38381f0ad16b7a82c2585a41921bafdaaa704393d863f828973be7c8aaec57d0`.
This rebuild changes the manifest wrapper; guest/kernel/rootfs derivations are
unchanged from the earlier verified KVM smoke. No new networking execution claim
is made here. Nix `--realise --check --keep-failed` also reproduced the new
manifest wrapper exactly; the rootfs link still names the earlier byte-verified
`5d7f5sx0vdw05gzqwiqb9ycl89whxv9c-ext4-fs.img`.

## Follow-up

Implement execution contract and driver, then integrate observed outcomes with
reservations, stop/start/delete and bounded crash recovery. Complete console
authorization/revocation and multi-host isolation acceptance before rollout.
