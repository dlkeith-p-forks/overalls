# Antithesis integration with current main

## Scope and architecture impact

This review covers the merge of the Antithesis rebuild at `17299fd9` into
`origin/main` at `cda064f36`, followed by upstream acceptance notes at
`282bd8084`, the ADR-0165 resource-policy activation fix at `dba649c6e`,
and its production Lilly uptime evidence at `b9d688a34`. The merge resolved nine
conflicts across application configuration, the experimental harness, native
verification and architecture documentation. It also retained the independent
changes from both review and ADR indexes. The assessment before resolution was
that current main's accepted production interfaces had to govern the harness:
the strict pool configuration from ADR-0159/0163/0164, the compile-time selected
controlled decoder, and the five-second ingress catalog limit under ADR-0142.
The final source diff preserves those interfaces. No new decision or
supersession is needed; this is compatibility work and verification evidence,
not a change to accepted authority or implementation status.

Affected decisions are ADR-0017 (durable Lilly ownership and actor execution),
ADR-0033 (native verification), ADR-0142 (control and ingress bounds), ADR-0149
(diagnostic separation), ADR-0159 (retired compatibility), ADR-0163 (standby
and capacity limits), ADR-0164 (ARC and dnode limits), and ADR-0165
(retaining unchanged consumers during activation). The existing fixture
work also touches the deployment and login boundaries described by ADR-0048 and
ADR-0065. ADR-0153 through ADR-0158 remain relevant to the proposed guest
journeys but gain no acceptance from this merge.

## Findings and resolution

1. **Resolved implementation incompatibility, high: retired pool key.** The
   incoming harness enrollment and Lilly startup configuration carried a pool
   field rejected by current main's strict pool shape. The merged
   [Lilly entrypoint](../../../antithesis/entrypoints/lilly.sh) and
   [inner host bootstrap](../../../antithesis/emulation/host/bootstrap.py)
   omit that key. [Production decoding](../../../lilly/lib/lilly/control/config.ex)
   retains the current main validation and bounded standby defaults. Only the
   compile-time controlled harness variant calls its separate
   [decoder](../../../antithesis/lilly/lib/overalls_antithesis/lilly/pool_config.ex).
   This preserves ADR-0159/0163/0164 without accepting a permissive production
   configuration. Composed startup must still establish that emitted enrollment
   and runtime configuration agree.

2. **Resolved verification schema drift, medium: ZFS observation.** Current
   main separates pool capacity from I/O rate samples. The
   [native ZFS test](../../../nix/verification/tests/machines/zfs-io/driver.py) now validates
   a typed `capacity` object separately from `io`; pool-wide logical rates
   cannot substitute for measured dataset capacity. This is a fixture repair
   under ADR-0033, not native execution evidence for the new harness.

3. **Resolved stale replay revision, medium: retained enrollment authority.**
   The [native resource fixture](../../../nix/verification/tests/machines/auto-update/native_resources.py)
   publishes a newer, valid 40-hex enrollment revision while resource replay
   is pending. It checks that replay updates the storage binding yet retains
   that revision through a later retry. This tests the current main replay
   contract; a passing complete native auto-update machine run remains separate.

4. **Preserved decoder correction, medium: bounded catalog decode.** The
   [catalog](../../../protocol/lib/overalls_protocol/ingress_catalog.ex) and
   [test](../../../protocol/test/ingress_catalog_test.exs) retain the current
   reset branch's five-second limit, narrowing main's previous thirty-second
   decoder to the existing publication contract. Ingress and refusal behavior still needs the
   consumer gates and composed acceptance on this merged source.

5. **Resolved documentation and formatting conflicts, low.** The ADR and
   review indexes include both branches. The small upstream
   [Overalls configuration](../../../fleet/hosts/overalls/configuration.nix) contract
   formatting repair separates two comment groups without changing their prose
   or runtime configuration. The HLDD
   continues from current main and adds five Antithesis scenarios and the
   five-second ingress description; receipt and generated-reference checks
   apply to that combined source.

6. **Resolved type integration error, medium.** Current main had removed the
   `Config` alias from [Lilly Runtime](../../../lilly/lib/lilly/control/runtime.ex),
   while the harness health helpers introduced `Config.t()` typespecs. Forced
   Dialyzer reported the resulting unknown type. Restoring the alias binds the
   typespec to `Lilly.Control.Config.t()` without changing runtime behavior.

## Verification and remaining gaps

The 28 verification unit tests, node contract checks, Ruff/ty checks and
logging hooks passed during conflict resolution. These are scoped
checks on the merge, not a complete native or hosted result. At this review's
source snapshot, the HLDD receipt was being refreshed after review and fresh
component gates were pending. Subsequently, Protocol, Lilly and satellite
application gates and forced Dialyzer passed. Marshall's isolated full suite
completed 1,475 of 1,476 checks successfully (238 of 239 properties and all
1,237 tests), with four exclusions, in 1,686.3 seconds. The sole failing MFA
login-history property reported a dead SQL sandbox owner. The exact property
passed in a fresh partition in 116.3 seconds. Its ExUnit limit is 240 seconds
while the default ownership timeout is 120 seconds; an ownership timeout is
consistent with the failure but not proven. This targeted pass does not turn
the full suite into a passing result. Marshall's final forced Dialyzer passed
after refreshing its PLT, with zero errors, skips or unnecessary skips and
1 minute 34.58 seconds of analysis. The full precommit command exited 2 because
of the sole ExUnit failure. Its toolchain, ADR (164 decisions), HLDD, contracts,
logging, compilation, formatting, terminal JavaScript (32 plus 8 checks),
workspace and monospace checks passed.

The incoming production uptime record establishes retained Lilly
uptime for the identified releases only; it does not establish Antithesis
acceptance. The earlier image identity and local boot captures predate the
current main merge, so they cannot identify the merged images. The four
selected images were subsequently rebuilt and frozen. The first
`snouty validate` exited 1 after enrollment exited 4: its retained oracle
fixture declared migration `20261010120000`, while the final source database
declared `20261013161738`. The retained-fixture equality check in the
[Marshall entrypoint](../../../antithesis/entrypoints/marshall.sh) correctly
refused this drift before publishing readiness. Existing volumes were
preserved and the same images were rematerialized under fresh project
`overalls-antithesis-main-control-core-20261013`. The next validation was stopped
after diagnosing a missing SQL column: migration `20261011180200` had retired
`compute_hosts.protocol_version` under ADR-0159, but the harness still queried
it. The corrected SQL witness uses a positive report sequence, a fresh report
timestamp and a durable session matching the current session ID, host ID and
epoch. It introduces no synthetic version constant; Execution and real Control
probes retain separate wire-v4 enforcement. Bootstrap and smoke require this
current authority witness. Fresh image identity and validation of the corrected
harness remain pending. No hosted run has been submitted. Composed acceptance
still needs matching source and
image identities. Native KVM isolation, independent physical
host failure domains, production deployment and the optional guest/editor
journeys retain their previously recorded acceptance gaps. No finding here
requires replacing an accepted ADR.
