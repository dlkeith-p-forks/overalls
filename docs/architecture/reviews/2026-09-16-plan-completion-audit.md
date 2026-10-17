# Plan completion audit

Date: 2026-09-16

## Scope and method

This audits the original Marshall/Lilly requirements and the accepted NixOS,
storage, secrets and machine-test plan in ADRs 0030–0033. ADR-0034 remains a
performance proposal. The preceding goal turn made concrete progress: it
completed the nine-machine fleet, recovery and credential-rotation checks and
updated their implementation evidence. This audit does not redefine the plan
around those successful checks.

Inspected the current modules, flake exports, resource/authorization boundaries,
collector, runtime pins and gates, test assertions, successful Nix output paths
and retained execution logs. The completion question is whether each requirement
has evidence at its own scope. A generic VM image does not prove compatibility
with an unavailable existing physical machine.

## Requirement mapping

| Requirement | Current evidence and assessment |
| --- | --- |
| At least three Marshall instances; configurations up to 100 | The [service module](../../../nix/domains/system/marshall.nix) validates 3–100 replicas, distinct local identities/ports and database budgets. The [fleet](../../../nix/verification/tests/machines/fleet/default.nix) runs three distinct machines with shared PostgreSQL and real failover. **Functional minimum verified; 100-instance throughput/production HA unverified.** |
| Privileged Lilly, multiple real Firecracker VMs per host and multiple hosts | The [Lilly module](../../../nix/domains/system/lilly.nix), [driver](../../../lilly/lib/lilly/vm/driver.ex) and [fleet driver](../../../nix/verification/tests/machines/fleet/driver.py) run six guests across two distinct nested-KVM machines, including daemon/machine/database failures. **Verified in one physical failure domain.** |
| Customer, Standard and OSS ranges; outbound access and no direct VM-to-VM access | The [packet matrix](../../../nix/verification/tests/machines/fleet/network.exs) covers actual routed egress, all 30 directed pairs, protected addresses and source/IPv6 guards. **Functional isolation verified; deployment routing/protected-address inputs remain required.** |
| User login, provisioning, per-VM readable/writable TTY and shared access | The [browser fixture](../../../nix/verification/tests/machines/fleet/browser.py) uses actual login, provisioning, sharing, writer handoff, guest-side effects and revocation through the production proxy. [Durable actors](../../../lilly/lib/lilly/vm/actor.ex) preserve local ownership. **Functional flow verified; broader terminal fault/load targets remain open.** |
| Continuous CPU/memory/disk capacity, architecture, utilization and IOPS | The [collector](../../../lilly/lib/lilly/host/collector.ex), [report ingestion](../../../marshall/lib/marshall/compute/host_reports.ex) and [admission budget](../../../marshall/lib/marshall/compute/budget.ex) preserve inventory, measurements, commitments and freshness separately. Native ZFS/I/O and fleet tests exercise actual observations and stale-report rejection. **Functional collection/admission verified; unknown IOPS maxima stay unknown until configured or measured.** |
| Ash domain modeling and background jobs | [Compute](../../../marshall/lib/marshall/compute.ex), [Accounts](../../../marshall/lib/marshall/accounts.ex) and Telemetry (`marshall/lib/marshall/telemetry.ex` at kittens revision `a99f74f0`, repository deleted) are Ash domains. Lifecycle, mail and retention work use AshOban; fleet races/outcomes exercise the actual persisted work. **Implemented and functionally verified.** |
| Ash archival, paper trail and Cloak | [VM resources](../../../marshall/lib/marshall/compute/virtual_machine.ex) retain archived identity/audit history after confirmed cleanup. [Host credentials](../../../marshall/lib/marshall/compute/host_credential.ex) apply all three extensions; [rotation](../../../nix/verification/tests/machines/credential-rotation/default.nix) verifies real encrypted credentials across nodes. **Implemented for the selected resources; audit retention and bulk re-encryption remain separate operational/design work.** |
| Cedar authorization | The [authorizer](../../../marshall/lib/marshall/authorization/cedar.ex) compiles and validates the actual schema/policies, then permits only error-free allows. Browser sharing/revocation and domain/property tests exercise enforcement. **Implemented and verified.** |
| Structured logging, properties, latest pinned Elixir and static analysis | [Version pins](../../../.tool-versions) select Elixir 1.20.4/OTP 29.0.6. [Marshall](../../../marshall/mix.exs), [Lilly](../../../lilly/mix.exs) and [Protocol](../../../protocol/mix.exs) enforce runtime, compiler, tests, contracts and Dialyzer. Consumer gates force protocol rechecking. Passing project gates and journal/URL-redaction checks are recorded in the fleet/custody reviews. **Verified at those scopes; no claim of complete static proof.** |
| Ongoing ADR/review guidance through skills and AGENTS.md | [Root guidance](../../../AGENTS.md), [ADR maintenance](../../../.agents/skills/adr-maintenance/SKILL.md), [architecture review](../../../.agents/skills/architecture-review/SKILL.md), the index and structural checker are present. **Implemented; this audit corrects stale active-ADR gap descriptions without rewriting superseded rationale.** |
| Reusable NixOS options for neither/either/both services | [Configuration assertions](../../../nix/verification/tests/evaluation/module-configuration.nix) and [role machines](../../../nix/verification/tests/machines/service-roles/default.nix) exercise real modules/packages. The combined role runs three colocated Marshall instances, Lilly and three proxy backends. **All role combinations and the strengthened colocation check passed.** |
| Source-built releases, TLS bridge, Route 53 ACME and external database boundary | [Packages](../../../nix/domains/artifacts/default.nix), [proxy](../../../nix/domains/system/proxy.nix) and [ACME](../../../nix/domains/system/acme/default.nix) pass source-release, verified-TLS/name rejection, issuance/renewal/reload and failure checks. **Local integration verified; real AWS/CA/database/SMTP inputs and provider acceptance unavailable.** |
| SSH host keys as age identities and pinned ghuntley key | The [secret module](../../../nix/domains/system/secrets/default.nix) and recipient package (`nix/domains/artifacts/operator-recipient/default.nix` at kittens revision `9fe1e493`, repository deleted) use the supplied public key without live GitHub lookup. Custody, recipient replacement and fleet credential-rotation suites pass. **Mechanism verified with synthetic private identities; actual encrypted deployment documents are not supplied.** |
| Sparse ZFS with LZ4 and no filesystem reservations | [Owned datasets](../../../lilly/lib/lilly/host/zfs_dataset.ex) and mirrored storage (`nix/domains/system/mirrored-zfs.nix` at kittens revision `16e8dbe4`, repository deleted) enforce the accepted policy. Native reader/lifecycle/guest/I/O/fleet tests verify allocation, ownership, pressure, deletion recovery and flushed-data survival after simulated host loss. **Functional behavior verified; physical performance/power-loss and representative headroom measurements remain open.** |
| NixOS VM Testing Framework, installer/QEMU artifacts and mirrored UEFI boot | The [flake](../../../flake.nix) exports fifteen checks. [Installation](../../../nix/verification/tests/machines/mirrored-installation/default.nix) and exact-image (`nix/verification/tests/machines/bootstrap-images/default.nix` at kittens revision `16e8dbe4`, repository deleted) suites pass real OVMF boot, independent surviving disks and SSH identity persistence/uniqueness. **Generic artifacts verified; the required existing-host configuration and its prior external boot test are missing.** |
| Optimal dense mixed-workload storage configuration | [ADR-0034](../decisions/0034-mixed-workload-storage-tuning.md) requires dedicated physical-guest measurements before promoting 16K/20%/cache candidates. **Unverified; no benchmark harness or representative hardware results exist. Functional VM timings cannot establish an optimum.** |

## Colocation review

The prior role suite exercised both applications together but only one local
Marshall instance. Configuration evaluation covered three local instances,
while the fleet's three replicas ran on separate machines. That left the
reference topology's combined runtime boundary untested.

The expanded [role driver](../../../nix/verification/tests/machines/service-roles/driver.py) checks three distinct
database/application identities, unprivileged services in the common Marshall
slice, effective CPU/memory limits, unchanged Marshall PIDs across Lilly restart,
proxy readiness with successively fewer backends, failure with none, recovery,
and unchanged Lilly PID across control-plane service stops. The fixture uses
explicitly reduced budgets; it does not substitute for physical-host performance
or compatibility with the unavailable reference host. Production modules and
accepted decisions are unchanged. Initial evaluation caught conflicting fixture
budget definitions; explicit fixture overrides resolve them without changing
module defaults or weakening assertions.

## Validation

The previous fifteen check outputs were present at audit start. Source-release,
fleet, native storage, custody, rotation and installation evidence remains
unchanged. The expanded role check passed in **104.32 seconds** using derivation
`42jz3n5bjzkhqxpa4d26ps6xgw9h2hpl-vm-test-run-kittens-service-roles`.
Its four machines verified the colocation assertions above, TLS rejection and
secret-free proxy logging. The fleet
log records 1108.23 seconds for its execution scope and 1108.96 seconds for the
framework's overall script timer; both refer to the same successful derivation.
The [fleet review](2026-09-16-nixos-fleet.md) and
[rotation review](2026-09-16-fleet-credential-rotation.md) retain their exact scope
and prior failures. All fifteen successful check outputs are present, including
the new role derivation. The pinned-runtime ADR checker passed all 34 decisions;
the contract checker passed 48 `CONTRACTS` files, 372 native notes and 453 covered
source files. `git diff --check` passed. These are structural checks, not additional
machine or physical acceptance. No application or shared-governance-tool source
changed in this audit, so the previously recorded project gates remain applicable.
Temporary build-user KVM access was removed after the machine test completed.

## Inputs and acceptance still needed

- The existing reference host's NixOS/disko/hardware/network configuration and
  original mirrored-boot test. They are absent from the accessible workspace;
  the earlier request for their location/content remains unanswered. The generic
  bootstrap must not be silently substituted for that existing host.
- Authenticated host public keys, encrypted deployment documents, real DNS/ACME/
  Route 53 and AWS PostgreSQL/TLS configuration, and SMTP provider inputs. Private
  keys and plaintext credentials belong in their private delivery workflow.
- Independent physical KVM failure domains and identified disposable benchmark
  storage, plus representative host/VM/terminal/request targets. The current
  nested virtual machines establish functional behavior, not these claims.
- Later operational capabilities remain explicit: authoritative historical fleet
  restore requires reconciliation under ADR-0029; tombstone/audit retention,
  guest-initiated lifecycle semantics and broader terminal faults need their own
  decisions or acceptance. They are not silently claimed by the NixOS milestone.

The entire plan is **not complete** while its required existing-host integration
and deployment/physical acceptance remain missing. CI hosting, unspecified extra
profile behavior and proposed tuning are not invented as completed features.
