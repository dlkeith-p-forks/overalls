# Declarative Lilly enrollment review

## Scope and architecture impact

ADR-0045 supersedes ADR-0012's historical one-year cap and adds an explicit
administrative SSH workflow and durable Ash operation records. It preserves ADR-0037's host serialization and reservation authority,
ADR-0043's installation bindings and explicit deployment, and ADR-0044's managed
recovery custody. Manual enrollment remains available; the lifetime ceiling grows
to five fixed-duration years without extending existing records.

## Findings and boundaries

- PostgreSQL and local publication are not one transaction. An operation UUID and
  immutable database result recover lost replies; per-file publication accepts
  only original or staged bytes. Journals contain ciphertext and public metadata.
- Matching preparation exports current authority without rotating. Old operation
  results cannot resurrect credentials after rotation or revocation.
- The root SSH bridge loads protected environment configuration through systemd;
  the release executes as an unprivileged account and retains verified DB TLS.
  Secrets are captured over SSH rather than printed as ordinary diagnostics.
- Concurrent provisioning and relocation edits were already in the checkout.
  This change preserves their current interfaces and does not claim their checks.

## Verification

- Marshall's first complete precommit run passed 296 cases (26 properties), the
  browser-state checks and forced Dialyzer. It included the three-node registration
  and rotation race. After adding retirement/storage-conflict coverage, the focused
  enrollment suite passed 19 cases (3 properties).
- The subsequent full run passed 297/298 cases and Dialyzer; its sole failure was
  the concurrently added `MarshallWeb.ProvisionerTransportTest` relocation-key
  preparation case, returning `:source_unavailable`. That code is outside this
  change; the earlier pass is not a claim that the later checkout is fully green.
- Nix enrollment configuration, preparation/custody, existing secret reconciliation,
  host planning, storage configuration and module configuration checks passed.
  These exercise real SOPS decryption by host/recovery recipients, outsider
  rejection, interruption/retry and conflicting generated-configuration overrides.
- The initial real SSH/systemd machine test passed concurrent retries, rotation,
  invalid requests, wrong-pin refusal and secret-free journal checks with the
  actual source-built Marshall release and verified database TLS.
- The expanded two-machine test passed in 130 seconds: actual host CLI over
  pinned SSH, native ZFS and application identities, SOPS delivery through the
  production secret unit, Lilly readiness, immediate rotation fencing, and
  readiness restored after installing the replacement ciphertext. It also passed
  concurrent retry, conflicting/invalid requests, stale operation rejection,
  wrong SSH pins and secret-free journal assertions.
- That expanded run used the already built Marshall and Lilly release artifacts
  with the current host CLI, Nix modules and fixture. Marshall's enrollment
  implementation matched the current files. The unmodified current flake build
  was blocked by concurrent SSH-management files missing from its Git source
  snapshot (`Marshall.SSH` was unavailable during compilation). The isolated
  acceptance result is not a claim that the whole moving checkout builds.
- The fixture activates the actual secret and Lilly units; it does not exercise
  the separate published-revision `enroll` command or a full NixOS switch. It uses
  generated credentials and a tiny local flake exposing the pinned nixpkgs library.
- ADR structure/link validation and `git diff --check` passed. Contract syntax and
  coverage passed in the precommit runs; semantic review traced shared lifetime
  validation, name/host locking, private export, generated Nix bindings and the
  ciphertext-only journal/publication path.

Unit simulations do not establish SSH, systemd, NixOS activation or physical-provider
acceptance. Real machine results are listed separately above.

## Remaining acceptance

Real provider deployment and actual operator recovery decryption require the
corresponding deployment inputs. No production credentials are used in tests.

The passing expanded test is
`/nix/store/22299ydw7cpa99ql176y2msgbycx42dr-vm-test-run-kittens-enrollment-operator.drv`.
The release artifacts used were
`/nix/store/bk9h9cb9ak30m3pjdfy98myfn49id73a-kittens-marshall-0.1.0` and
`/nix/store/cna8l5c22ra7gkdg17j0i8lbfnnsy8h1-kittens-lilly-0.1.0`.

## Commit isolation

The enrollment commit excludes concurrent provisioning, relocation and SSH
management work. Its profile includes a minimal prerequisite: force the reviewed
GRUB device list so Disko cannot append duplicate BIOS targets. This preserves
ADR-0043's boot-device selection and has no new architecture impact.

All six Nix evaluation/custody checks also passed against the isolated commit
snapshot, including the GRUB prerequisite. ADR validation passed with 45 decisions.
