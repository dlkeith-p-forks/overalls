# ZFS-only provisioning and provisioner v2

Date: 2026-09-16

## Scope and architecture impact

The authorized development breaking change removes ext4 **host backing** and
receipt-only provisioner v1. Guest ext4 filesystems, console/credential/ownership
formats, and the fifteen public Nix checks remain. The preceding Nix layout
refactor is preserved. [ADR-0035](../decisions/0035-zfs-only-provisioning.md)
supersedes ADRs 0012, 0016, 0025 and 0031, carrying forward their execution,
authentication, ownership, accounting and recovery requirements.

## Findings and changes

- **Resolved implementation drift — alternate backing:** Lilly pool discovery,
  disk preparation/deletion and collection now use native ZFS exclusively.
  Sparse copies retain the guest ext4 image; no preallocation, statfs credit or
  Linux diskstats fallback remains. Plain block-device validation still protects
  ZFS backing identity and duplicate-device rejection.
- **Resolved contract ambiguity — admission:** enrollment, reports, Nix options,
  Ash resources and database constraints require ZFS identity and an explicit
  positive logical budget. Missing capacity cannot fall back to physical total.
  Freshness, reservations and outcome-confirmed release remain separate.
- **Resolved obsolete protocol — receipt-only execution:** both applications and
  shared codecs use provisioner v2. Full image/address intent, physical machine
  identity, fencing and outcomes remain required. Old API requests fail with an
  unsupported-version response; independent version-1 formats remain unchanged.
- **Verification coverage:** synthetic fixtures now carry coherent ZFS data.
  Obsolete ext4 allocation assertions are removed. Real collector failure,
  missing-image and revocation cases move to the ZFS fleet suite. Native machine
  tests exercise ownership-safe disposable ZFS fixtures used by privileged local
  harnesses. Cleanup requires matching GUID, mount and UUID owner and uses
  nonrecursive destruction after guest cleanup.
- **Development schema break:** generated migrations enforce ZFS-only pools and
  protocol v2. No conversion of existing development data or mixed-version rollout
  is promised. Historical migrations remain historical schema evidence.

## Verification

- Protocol precommit: 25 passed (13 properties, 12 tests); Dialyzer passed.
- Lilly precommit: 94 passed (23 properties, 71 tests); Dialyzer passed.
- Marshall precommit on a fresh isolated database: 231 passed (25 properties,
  206 tests), six browser queue tests passed; forced Dialyzer passed with the
  existing one upstream typespec exclusion. Direct SQL tests verify the new
  constraints in addition to Ash validation.
- Six deployment-fixture ownership regression tests passed. Python and Elixir acceptance
  harnesses and machine drivers parse. The historical maintenance migration
  backfill, constraints and rollback refusal passed in a disposable database. ADR and contract structural gates passed.
- All fifteen exported Nix checks passed for the ZFS-only snapshot below. Twelve
  checks built in this run; three retained successful unchanged derivations.
  Public package/module/machine export names match the pre-refactor inventory.

| Check | Result | Derivation |
| --- | --- | --- |
| module-configuration | built and passed | `3m2n5k5djmnwvmzvs086g8dc8xqkklsd-kittens-module-configuration-check.json.drv` |
| storage-configuration | cached, unchanged derivation | `pynla3c6hr571aiibyy7zj8q8yy9fq4h-kittens-storage-configuration.drv` |
| marshall-release | built and passed | `jqq4p8ncnjv5hfq153w07q77dh71cr4n-marshall-source-release-check.drv` |
| lilly-release | built and passed | `1qch8kqs98hb920hfg0rcqjbi45wzx2p-lilly-source-release-check.drv` |
| native-zfs | 270.31 s machine script | `wzkw11av7kbhiqhjwc4rn6y7b60sxgp4-vm-test-run-kittens-native-zfs.drv` |
| zfs-lifecycle | 753.67 s machine script | `0whcdgi6nd8acadsc997lgwa4vd2vxfj-vm-test-run-kittens-zfs-lifecycle.drv` |
| zfs-guest | 636.70 s machine script | `8h1dcl9lszbb76hjsgclkrq9x4bachws-vm-test-run-kittens-zfs-guest.drv` |
| zfs-io | 74.83 s machine script | `s0l8fzhyzi2h8ry56ag9wyxagms003w5-vm-test-run-kittens-zfs-io.drv` |
| service-roles | 98.68 s machine script | `3rrcy7pkrdzvrfm5arl07f03j8ynch75-vm-test-run-kittens-service-roles.drv` |
| acme-route53 | 133.74 s machine script | `9jwn3fg6g4dfbf87740c1ww6skdn0pfh-vm-test-run-kittens-acme-route53.drv` |
| secret-custody | 135.78 s machine script | `j3cz6qznzd6q25pl65yhn4482s9f59rf-vm-test-run-kittens-secret-custody.drv` |
| credential-rotation | 259.66 s machine script | `344nzylprqdv5zy0x3ii1hkpvkcad82p-vm-test-run-kittens-credential-rotation.drv` |
| mirrored-installation | cached, unchanged derivation | `saqjzcibsmqffwna78dw23jnj094islr--test-run-kittens-mirrored-installation.drv` |
| bootstrap-images | cached, unchanged derivation | `81vyl7w0c4nwcc6882lgkxxzjp21f778--test-run-kittens-bootstrap-images.drv` |
| fleet | 1177.88 s machine script | `w98ya6ib8dlxlbr357d7lvrgrgmx7vb3-vm-test-run-kittens-fleet.drv` |

The first Marshall run exposed remaining distributed RPC fixtures using removed
v1 entry points and a drain fixture without a sufficient logical budget. These
were corrected; the complete rerun passed. The static VMM configuration tests
now explicitly select the pinned static Firecracker directory instead of relying
on an inherited PATH that selected a dynamic binary. Production ELF validation
was retained. The first native ZFS run caught device discovery calling the pool
comparison helper with raw extents. Device-overlap validation now has a separate
typed API, covered by a regression test; duplicate and overlapping devices still
fail closed. Machine checks were restarted against the corrected source. The credential
rotation fixture also attempted to supply the now-internal protocol version to
Ash enrollment; it now uses the enforced v2 default and supplies only its
required machine identity.

The sequential guest run reproduced a bulk image flush exceeding the generic
three-second utility deadline. Disk file flushes now use the same explicit
five-minute bound as image copying. Flush success remains mandatory before
publication/launch; a timeout still fails closed and preserves recovery state.
Metadata operations retain their existing deadlines. A subsequent Marshall run
exhausted the local database connection limit because its test pool scales with
CPU count; rerunning with `ERL_FLAGS="+S 4:4"` passed all 231 cases and forced
Dialyzer without changing the three-node tests. All affected machine suites
subsequently passed; the table records only the final derivations. The fleet also passed the added collector-failure, missing-image
and credential-revocation scenarios with real ZFS and v2 transport.

## Verification boundary

Concurrent automatic-update work was added to the shared checkout while the
immutable Nix derivations were running. The verification baseline is commit
`aa5ecf1` plus removal of the unsupported `protocol_version` argument in the
credential-rotation enrollment fixture. An isolated checkout reproduced fourteen
checks exactly. Credential rotation was rerun successfully there because its
earlier evaluation picked up an intermediate concurrent secret-preparation
change. All fifteen table entries now match this one reproducible baseline. They
do not establish acceptance of subsequent automatic-update modules, readiness
APIs or modified fleet scenarios. Those changes remain intact and belong to
their own review. The temporary KVM ACL used by this run was restored after its
machines exited.

## Remaining acceptance and limits

Machine verification is complete for this change. No actual physical-host
activation, hardware performance claim or production rollout is established by unit tests or nested
VM tests. The privileged standalone acceptance harnesses have been converted but
have not each been executed end to end in this change. Their behavior is covered
in part by the native fixture and fleet suites; this is not equivalent to claiming
those standalone runs. The independent deployment inputs and physical acceptance
items in the [completion audit](2026-09-16-plan-completion-audit.md) remain open.

## Final assessment

The final diff removes the alternate backing and receipt-only API across runtime,
configuration, codecs, schema, fixtures and current documentation. Guest ext4,
independent version-1 formats, the prior Nix layout, and all public checks remain.
ADR-0035 is implemented for this scoped removal. Its predecessors retain their
historical rationale and evidence; independent deployment acceptance and proposed
performance tuning remain outside this implementation claim.
