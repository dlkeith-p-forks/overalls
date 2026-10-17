# Operator secret recipient histories

## Scope and architecture impact

Improvement 032 adds generated operator verification on base
`fff6587e48b91897484dd9aa6a6ad769d26eb8f4`. Production code, authority, protocols,
configuration and publication contracts are unchanged. ADR-0041 requires all
recovery users, only selected hosts, retained-identity reconciliation, new data
keys and atomic per-file publication. ADR-0044 adds explicit recovery-only
custody; ADR-0067 and current ADR-0086 carry those requirements forward. No
new decision or implementation-status change is needed. ADR-0009/0033 evidence
boundaries remain in force.

The public package normalizes reviewed users and inventory through
[Nix option types](../../../nix/platform/lib/registry.nix), then supplies that public
manifest to [the CLI](../../../nix/domains/artifacts/secrets/cli.py). Generated fixtures
use those valid shapes. Malformed policy booleans are not modeled as a new
public attack surface. The existing fixed policy-refusal cases remain.

## Existing evidence and new composition

The existing [reconciliation tests](../../../nix/verification/tests/evaluation/secrets_test.py)
contain 14 fixed actual SOPS cases, including add/remove, hostless custody,
preflight, idempotence, safe output and interrupted publication/retry. The
[systemd environment properties](../../../nix/verification/tests/machines/secret-custody/properties.py)
already generate 40 environment roundtrips and check interruption. These are
credited separately from the new recipient-history properties.

Historical native custody and host/replacement rotation passed in **135.90
seconds** with `qznzhiy5msbanzza00ci46mpr54gc6rd-vm-test-run-kittens-secret-custody.drv`;
the [original review](2026-09-16-secret-host-rotation.md) retains scope and
limitations. Coordinated credentials passed across three Marshall machines in
**249.75 seconds**, as recorded in the [rotation review](2026-09-16-fleet-credential-rotation.md).
Neither result is a new run or evidence for every generated history.

The [new histories](../../../nix/verification/tests/evaluation/secret_recipient_histories.py)
execute the production CLI entry point for encrypt, check, rekey and decrypt:

- Twelve generated histories compose recovery membership/key overlap, host-key
  overlap/retirement, selected host sets and an explicitly hostless document
  across JSON, YAML and YML. Every history adds and removes recovery identities;
  up to two generated intermediate policies change their order/composition.
- Expected decryptors derive only from logical key IDs and generated operations.
  Seven runtime-generated SSH identities independently convert through actual
  ssh-to-age. Actual SOPS decryption checks retained/new identities, removed
  identities, nonselected hosts and a login-only outsider against unchanged
  plaintext. Actual age decryption of the retained recovery envelope compares
  data keys before and after each transition.
- Repeated checks, refused rekey and no-op replay preserve ciphertext, inode,
  permissions and exact repository/private-file inventories. CLI decrypt
  verifies mode-0600 output and no output on outsider refusal.
- Eight generated interruption histories plus explicit first-before and
  last-after boundaries corrupt a later candidate and require all-original
  preservation. A subprocess invokes actual main with only its publish function
  wrapped to fail immediately before or after the selected real publication.
  The exact completed/possibly-updated report, observed per-document decryptors
  and explicit normal CLI retry must agree; retry preserves completed ciphertext.

The fault seam does not simulate power loss, fsync failure or concurrent external
writers. Per-file partial publication is accepted behavior, not multi-document
atomicity. Normal commands use the unmodified CLI. The wrapper does not replace
cryptography, preparation, original revalidation, directory locking or publication.

## Private fixture custody and contracts

Each example creates a private mode-0700 temporary tree outside the checkout and
Nix store. Keys and plaintext are runtime-generated; private bytes never enter
arguments or output. Required file path arguments use the existing public CLI
interface. Captured diagnostics are checked for private bytes, plaintext,
tracebacks and private filenames; failures print only exception class/source
locations. Public Hypothesis policies contain only small integers/booleans.
Temporary identities must disappear after success and failure, and owned trees
are removed by context-managed teardown.

Reviewed root, Nix/test and operator custody/publication contracts, local CLI
contracts, public wrapper and all new oracle/fixture consumers. New contracts
require an independent decryptor oracle, disposable custody, exact refusal/replay
inventories and truthful partial-publication retry. No contract violation or
production defect has been reproduced. Contract syntax/discovery alone does not
establish those semantics.

## Executed validation

- The exact exported `checks.x86_64-linux.secret-reconciliation` passed **14
  fixed tests, 12 generated recipient histories, 8 generated interruption
  histories and 2 explicit interruption boundaries**. Final derivation:
  `/nix/store/k55qp2q5dq1qn0a6da4cl9qj8alzxn7i-kittens-secret-reconciliation.drv`;
  output `/nix/store/lr6mhy3vh7508akh1m1h8hi13bzx7smk-kittens-secret-reconciliation`.
  The final command completed in 144 seconds; its build log reports the fixed
  suite in 4.685 seconds and both property completion markers.
- Executable inputs are captured in staged tree
  `6c741a5ea1ec46c2c36937f05780650248e8b76e`; documentation was separately in
  progress during that run. The history file SHA-256 is
  `7678d449b7dcc5fd2ef11f7114572cd88b008638ed5f27c6d782c31faa598abc`.
  The unchanged production CLI SHA-256 is
  `0cb7d3514cdae3f81f02210cfddf18c65703a51e43b0d89f3f0f1b33264824a7`.
- Initial candidate `ebe79e66a6304d5ef0954c7c2111452ed476ac65` also passed the
  complete exported gate in 126 seconds, output
  `/nix/store/jfx9b05pjsd3xsvy7cd6wkh4ykhdj9mg-kittens-secret-reconciliation`.
  The first direct type-check invocation failed because it omitted the pinned
  dependency interpreter and assigned an undeclared ModuleType attribute. The
  fault seam now uses `patch.object`; configured all-file Ruff format, Ruff lint
  and ty hooks pass. This was a fixture/type-check correction, not a production
  failure or test skip. Both runtime logs and the initial static failure are
  retained in `/tmp/verify032-nix1.log`, `/tmp/verify032-nix2.log`, their
  `-build.log` companions and `/tmp/verify032-static1.log`.
- Contract format/coverage and discovery pass; ADR structure/link checks and
  generated coverage, options and ownership/topology checks pass. Reviewed
  receipts, full all-file prek (including configured Ruff/ty and logging checks)
  and Nix HLDD pass. The initial documentation gate completed in 24 seconds,
  output `/nix/store/n2xhcqsc37wqrqq1r5k48169gcw3nan8-kittens-hldd-check`;
  final evidence bookkeeping is rechecked before commit. No executable source
  changed after the final cryptographic run.

## Remaining gaps

No new native run: systemd, host identity, transport and application credential
consumers are unchanged and retain the recorded native scopes above. Generated
local CLI histories do not establish privileged delivery, off-host recovery-key
availability, provider IAM, physical disaster recovery, arbitrary power loss,
concurrent writers, fleet rotation compatibility or revocation of plaintext
already learned by removed recipients. Rotate application credentials separately.
No Inception tests or validation were run. No application or shared-governance
code changed, so application precommit suites are outside this improvement.
