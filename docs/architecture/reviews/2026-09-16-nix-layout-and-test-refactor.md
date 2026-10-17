# Nix layout and test refactor

Date: 2026-09-16

## Scope and architecture impact

The scope is the deeper Nix refactor and retirement of the manual deployment
directory: organize by responsibility, give each machine suite its own directory,
split large/embedded drivers and share existing fixtures. Application test
layouts and runtime behavior remain unchanged; the existing execution smoke
script now reads its service fixture from the test tree. The
[layout guide](../../../nix/README.md) and
[test catalog](../../../nix/verification/tests/README.md) describe the resulting ownership.

This preserves ADRs 0011, 0028 and 0030–0033. There is no replacement deployment,
storage, custody or verification decision. Source links and implementation
evidence move with the code; decision statuses, rationale, previous run hashes
and physical/deployment acceptance gaps remain intact.

## Findings and changes

- **Maintainability:** the flat test directory mixed machine definitions, driver
  fragments and guest-side fixtures. Suites now live under `tests/machines/`,
  alongside their own probes. Evaluation and release checks have separate groups;
  the explicit catalog retains every public check name.
- **Maintainability:** a 514-line fleet driver obscured its stateful scenario
  order. Initialization, helpers, browser coordination and ten scenario files are
  assembled by an explicit list at Nix evaluation time. The full generated script
  remains subject to framework lint/type checks. ACME and secret-custody Python
  now reside outside Nix strings with explicit generated-path preambles.
- **Fixture consistency:** fleet and rotation duplicated PostgreSQL/TLS setup.
  The shared fixture retains private runtime generation, TLS-only network access,
  explicit migration and diagnostic suppression. Callers still specify their
  distinct 64/32 connection limits, generation-service identities and the same
  restricted management network. Role-local database setup stays separate.
- **Custody:** the common transfer helper retains absolute private temporary
  storage outside retained output, removes local copies on exit and never prints
  values. Runtime credential generation and VMM inspection are shared explicitly;
  suite-specific fault and browser/provider fixtures remain local.
- **Build boundaries:** guest, toolchain, host helper and recipient definitions
  now belong to packages. ACME and secret-preparation scripts belong to their
  modules. Development imports, the flake and documentation use the new paths.
  No dependency version, public option or source allowlist changed.
- **Deployment ownership:** `deploy/` and its environment examples are removed;
  the deployment guide now directs operators to NixOS. Four byte-identical
  historical service/proxy definitions and their applicable contracts moved to
  test-only fixtures (`scripts/test/fixtures/legacy-deployment/README.md` at kittens revision `9fe1e493`, repository deleted).
  The deployment, database-recovery, fleet-characterization, terminal and execution
  harnesses retain their complementary coverage. Their callers use the new paths;
  historical ADR links retain the earlier topology and evidence. The old
  passthrough fixture is explicitly separate from production NixOS TLS bridging.

## Verification

Before moving files, captured all public export names, all fifteen check
derivations and all 61 explicit scenario declarations. The current export names
and scenario inventory match. An AST comparison confirms unchanged fleet scenario
statements and helper bodies except for the extracted transfer helper. Twenty-eight
relocated probes, fixtures, runtime helpers and the public key are byte-identical.
Machine
runs remain necessary to verify composition and wiring.

Five checks retain their exact successful derivations: module configuration,
storage configuration, service roles, bootstrap images and mirrored installation.
Both relocated release checks passed; their application/runtime dependency
derivations are unchanged. The pinned development runtime check passed Elixir
1.20.4/OTP 29.0.6. ADR and contract structural checks passed after the moves.
The assembled fleet driver passed framework type and lint checks. The ACME
machine run passed in 133.25 seconds and secret custody in 135.56 seconds
(framework script timers). The relocated guest check subsequently passed in
662.91 seconds. The lifecycle run failed on a disk sync timeout while other
suites were running; fleet had not run before the ZFS-only change began. These
results do not establish acceptance of that intermediate revision. The
ZFS-only revision subsequently passed all fifteen exports, including every
relocated suite; exact results appear in the
[ZFS-only review](2026-09-16-zfs-only-provisioning.md).

All four retained legacy fixture bodies match their original Git versions. The
six fixture-ownership regression tests passed and all four Python acceptance
harnesses parse. Marshall's precommit gate passed for the execution-smoke path
update: 227 checks (25 properties and 202 tests), four host checks excluded,
compiler and forced Dialyzer gates passed with the existing one upstream
typespec exclusion. No legacy privileged acceptance run is claimed by these
path and ownership checks.

An initial flake evaluation overlapped the final shared-fixture signature edit
and saw an inconsistent intermediate argument list. The complete subsequent
check-set evaluation succeeded after edits stopped. No assertion was weakened.

## Remaining acceptance

The final ZFS-only revision passed all fifteen exported checks and structural
gates, retaining the existing scenarios and adding native-fixture and fleet
failure coverage. Public exports remain unchanged.
Independent physical failure domains, hardware performance and the missing
existing reference-host/deployment inputs remain the separate obligations in the
[completion audit](2026-09-16-plan-completion-audit.md).
