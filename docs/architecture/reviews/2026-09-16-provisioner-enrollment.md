# Protected provisioner enrollment review

## Scope and architecture impact

ADR-0025 implements the operator workflow left open by ADR-0012, retaining
ADR-0017's physical-host ownership and execution boundary. Existing Ash Compute
resources remain authoritative; no tables, public endpoints or wire protocol
versions are added. Lilly accepts a private credential envelope alongside legacy
inline configuration. The user's implementation instruction authorizes this
refinement. Existing decisions are not superseded.

## Findings and resolution

- **High, protected issuance:** bounded requests specify machine identity,
  architecture, host/pool overheads and TTL. Existing names and physical IDs are
  not overwritten. Host, pools, credential and its secret-free audit history share
  a transaction. New hosts remain disabled with no fabricated capacity.
- **High, filesystem authority:** outputs use exclusive creation in an existing
  service-owned 0700 directory, become 0600 before writing, and sync file data and
  directory entries before commit. Readers reject symlinks, hard links, unsafe
  ownership/modes and oversized files. Canonical trusted parents prevent other
  local users from replacing paths. The service account and root are trusted.
- **High, explicit commit uncertainty:** PostgreSQL and local files are not one
  atomic storage system. A tested rollback after a synced output leaves an
  inactive artifact. Failed commands retain files, and retries cannot overwrite
  them. Verification consults current credential authority; metadata lookup by
  name recovers IDs after a lost response. Storage/power-loss behavior still
  depends on the deployed filesystem and database durability configuration.
- **High, corrected recovery result:** a decryption failure was initially treated
  as an inactive credential. Verification now distinguishes unavailable authority,
  inactive credentials and invalid files. A corrupt-ciphertext regression proves
  that failed decryption cannot justify discarding the only credential copy.
- **High, rotation and admission:** the existing host lock serializes rotation,
  revocation and enable/disable. Rotation invalidates observations/sessions while
  retaining VM allocations. Enabling requires a fresh v2 execution-ready report;
  subsequent admission still applies the existing capacity/image checks. Disable
  prevents new admission/start and does not stop guests or complete a drain.
- **High, local credential consumption:** Lilly rejects ambiguous inline/file
  credentials and envelopes bound to another host. Existing v2 machine identity
  and server-side expiry checks remain authoritative. Files are read at startup;
  installation and restart are intentional operator steps, with a control-plane
  interruption during rotation. Existing VMMs retain their independent lifetime.
- **Medium, corrected operator startup:** starting a full serving application for
  an operator command could conflict with web ports or consume unrelated jobs.
  Standalone CLI startup now runs only Repo, Vault and Cedar. A built-release
  smoke with `PHX_SERVER=true` confirms there is no endpoint or Oban consumer.
- **High, secret handling:** primary logging filters redact tagged operator
  diagnostics. Exceptions return fixed reasons, and outputs contain only public
  IDs/metadata. Credentials travel in private files, never command arguments.
  Administrative file transfer, OS account controls and key custody remain
  deployment responsibilities; no public bootstrap identity is implied.

## Verification

Both projects' final precommit gates passed: Marshall 198 cases (20 properties,
178 tests), plus six browser-state checks; Lilly 81 cases (18 properties, 63 tests).
Compiler/runtime gates and Dialyzer passed on Elixir 1.20.4 / OTP 29.0.6. Marshall
retains its one existing upstream exclusion; Lilly has no exclusions. Four
unrelated opt-in host checks were excluded from Marshall's suite.
`mix ash.codegen --check` confirmed there are no new migrations. The structural
ADR checker passes all 25 decisions.

Both production releases built. The actual Marshall release executed enrollment,
verification, public lookup, readiness rejection, rotation and revocation against
the test database with temporary keys. Outputs stayed private and existing paths
were refused. Teardown deleted only that uniquely named smoke host, pools and
credential/audit fixtures. No real host was activated or external credentials
transferred. The cross-application integration test uses Marshall's exported
file through Lilly's real client and a verified local TLS listener.
The built Lilly release also loaded a separate credential file through its actual
startup-configuration module without exposing the token. Logs in this development
environment are `/tmp/kittens-enrollment-final-gate.log`,
`/tmp/kittens-enrollment-lilly-gate.log`,
`/tmp/kittens-enrollment-release-smoke.log` and
`/tmp/kittens-enrollment-lilly-smoke.log`.

Review inspected source, configuration, tests and generated release behavior.
The current repository has no commits and its files are untracked, so historical
Git diff review is unavailable. Existing Git state and unrelated files remain.

## Follow-up

Complete deployment-specific secret transport/custody and rotation scheduling,
host drain/replacement workflows, operational key rotation/re-encryption, second
physical-host execution, terminal failover and representative fleet/load
acceptance. The file workflow and single-host fixtures do not establish those
remaining requirements.

## Evidence

[Enrollment](../../../marshall/lib/marshall/compute/enrollment.ex),
[request validation](../../../marshall/lib/marshall/compute/enrollment_request.ex),
[private file operations](../../../marshall/lib/marshall/operations/private_files.ex),
[privacy](../../../marshall/lib/marshall/operations/privacy.ex),
[CLI](../../../marshall/lib/marshall/operations/cli.ex),
[application modes](../../../marshall/lib/marshall/application.ex),
[Lilly credential reader](../../../lilly/lib/lilly/control/credential_file.ex),
[runtime configuration](../../../lilly/lib/lilly/control/config.ex),
[integration tests](../../../marshall/test/marshall/compute/enrollment_test.exs),
[request properties](../../../marshall/test/marshall/compute/enrollment_request_test.exs),
[file/privacy tests](../../../marshall/test/marshall/operations/private_files_test.exs),
[Lilly configuration tests](../../../lilly/test/lilly/control/config_test.exs),
[Lilly envelope properties](../../../lilly/test/lilly/control/credential_file_test.exs),
[operator guide](../../operations/provisioner-enrollment.md).
