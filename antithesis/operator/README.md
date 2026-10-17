# Private fixture operator

The enrollment container runs `control-operator.sh` as its main process. Before
publishing enrollment readiness, it creates synthetic accounts by consuming
magic-link tokens through the production Ash sign-in action, registers and
verifies P-256 passkeys through `User.security`, grants the second administrator
through `User.set_administrator`, and registers `github/fixture/demo` through
`Catalog.register` (Marshall commits the canonical lowercase source identity,
which the manifest, the origin fixture's served path and the workload's
readiness probe all share). The private result is
`/run/overalls-control-secrets/fixture.json` (mode 0600). It contains the actual
user and repository IDs and synthetic passkey key material needed by the
browser workload. It supplements the independent, nonsecret
`/run/overalls-oracle/fixture.json` identity manifest.

Bootstrap records a durable `fixture-bootstrap.started` marker in the private
control volume before the first mutation. If bootstrap fails before publishing
the manifest, operator restart refuses the partial fixture. The private
`bootstrap-stage` file contains only a fixed phase name, such as
`admin_a.begin_register`; it contains no account or credential data. Preserve
the failed project's volumes for diagnosis and use a fresh isolated Compose
project and fresh volumes for a rerun.

The operator reads only root-owned, mode 0600, single-link JSON files named
`/run/overalls-control-requests/requests/<uuid>.json`. Every request has version
1, a `request_id` equal to its filename, one named operation, and exactly that
operation's fixed fields. Results are atomically published to the matching
`results/<uuid>.json`. `refused` means the request shape failed before action;
`uncertain` means a trusted action or its receipt could not be established and
must be reconciled by the workload. The operator marks a mutation started
before invoking the release and never automatically retries an ambiguous one.

The closed operation names and exact request schemas are in
`entrypoints/control-operator.sh`. `rotate_lilly` uses the reviewed host CLI;
`refresh_repository` and `demote_admin_b` obtain fresh stored logins, complete
real passkey assertions, then call the production Ash coordinator. The
`compute.*`, `terminal.*`, `integration.*`, and `guest.*` operations are fixed
runtime modules loaded from this directory. They accept only fixture roles,
catalog identities and bounded action fields; their receipts are control
outcomes. Independent SQL, Enrico, Lilly or guest witnesses are required for
physical-effect claims.

When the optional host graph sets `OVERALLS_ANTITHESIS_HOST_ENROLL=1`, the same
operator copies the synthetic CA into `/run/overalls-host-secrets`, waits for the
inner host's measured `lilly-host-enrollment.json`, and uses the reviewed
Marshall CLI to enroll and verify it. A durable started marker prevents
ambiguous reissuance. It publishes `lilly-host-credential.json`,
`lilly-host-pool-id`, and the nonsecret
`/run/overalls-control-secrets/host-fixture.json` only after observing the
committed host and pool. The default oracle fixture retains its single
`lilly-a` host ID; host-specific workloads use `host-fixture.json` and the
inner host's independent health observation.

No request can name an Elixir expression, source file, shell command, arbitrary
user identity, authentication secret or external repository. Runtime secrets
stay in private volumes and are excluded from process output.
