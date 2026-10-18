# Guest reflection architecture review

The change adds the Peach private service and a protocol projection. It keeps
authorization and dedicated credential persistence in Marshall, routing in Audi,
and execution policy in Lilly. Peach has no database authority. The projection is fenced by VM,
placement, execution epoch, host, and completed start operation, and redacts
header values and credentials.

Implementation is partial. The NixOS module packages Peach with systemd credential
custody, but the declared fleet does not enable it. Marshall owns the dedicated
host credential, digest-only storage, rotation/revocation and secret-free
PaperTrail versions; ordinary users cannot access either credential resource.
The database-backed credential lifecycle and refusal tests passed in the focused
Marshall run recorded below.
Peach's current HTTP-named test only
validates a projection fixture through the codec and does not invoke the Plug.
Successful packaged guest projection, execution/expiry histories, native
isolation and cross-host recovery remain unverified.

Merged deployment review found that requiring Peach beside Audi blocked hosts
that had not enabled reflection, while Audi's closed runtime decoder rejected
the emitted socket field. The repair makes that field optional and nullable,
validates configured canonical bounded Unix paths, and refuses absent reflection
before guest execution admission. Lilly, Ziggy and Galileo remain mandatory.
This enables independent rollout; it does not establish enabled Peach socket
access, service credential lifetime or a successful native projection.

## Recorded focused verification

The optional-rollout source patch captured in merge `964f5ca82` is unchanged in
the five Audi/Nix files at post-pull `3e25e8218`.

- The pinned `mix test test/config_test.exs` run passed **15 tests**, seed
  **719595**, in **0.6 seconds**. It exercises absent/null/configured Peach
  socket validation, malformed path refusal and disabled reflection refusal
  before connector authority. Log: `/tmp/cli-routing-audi-config-test-final.log`.
- `checks.x86_64-linux.ziggy-configuration` passed in **11 seconds**, including
  the explicit assertion that the private service fixture works with Peach
  disabled. Log: `/tmp/cli-routing-ziggy-evaluation.log`.
- Both enrolled host failed-assertion projections returned `[]` for
  `nixosConfigurations.overalls.config.assertions` and `dungarees`, filtering
  failed entries to their messages. Results are in
  `/tmp/cli-routing-overalls-assertions.json` and
  `/tmp/cli-routing-dungarees-assertions.json`.
- The post-pull reflection protocol focused run passed **2 tests**, seed
  **276415**, including **100 generated comment cases** with explicit
  2048/2049-byte, NUL and invalid-UTF-8 boundaries.
  Log: `/tmp/protocol-reflection-focused.log`.
- The corrected private-services suite passed **4 tests**, seed **404368**, in
  **0.02 seconds**. Its fixed certificate-name expectation includes reflection;
  the function still has no runtime consumer and does not validate a deployed
  leaf. Log: `/tmp/osmatrix-protocol-private-focused.log`.

These are decoder/Plug, protocol and Nix configuration results. They do not
enable Peach, run its HTTP Plug, exercise deployed private routing or prove
native isolation.

Read-only deployed leaf inspection found only `llm.internal` and
`*.integration.internal` SANs. Disabled Peach requires no certificate mutation;
current health checks verify `llm.internal`, and the protocol certificate-name
list has no runtime consumer. Before reflection enablement, the operator must
reissue the private leaf through existing offline issuer custody with the fixed
`reflection.internal` SAN. No certificate or private key was changed, and neither
the current health check nor the names-list test establishes reflection TLS.

The schema follow-up adds a forward
[Peach reconciliation migration](../../../marshall/priv/repo/migrations/20261018213000_reconcile_peach_credential_schema.exs)
and generated credential/version snapshots, retaining credentials while aligning
database defaults, the partial active-host identity index and the host reference.
The reflection metadata migration had collided with the newsletter's timestamp;
read-only production inspection found both versions' effects absent, so only the
unapplied reflection filename was given a unique version. Its schema body is
preserved; no applied schema was rewritten or production database mutated.
Machine and integration comment constraints retain the empty-string default so
ordinary admission/registration without a comment remains valid; integration
updates also accept the coordinator's comment field. Generated VM and integration
snapshots add only the already-migrated labels/comment schema and hashes.

The final focused Marshall run passed **40 tests** in **12.4 seconds**, seed
**587216**, after fresh migration setup. From `marshall/` in the pinned shell:

```sh
mix test test/marshall/accounts/newsletter_dismissal_test.exs test/marshall/peach/credentials_test.exs test/marshall/control/peach_service_test.exs test/marshall/paper_trail_policy_test.exs test/marshall_web/overview_live_test.exs test/marshall/newsletter_property_test.exs test/marshall/galileo_test.exs
```

Log: `/tmp/marshall-focused-final.log`. The included Peach tests exercise
rotation/revocation, secret-free audit, ordinary-user refusal and dedicated
credential service admission. Overview and Galileo fixtures exercise admission
and integration registration/update with empty comments. This is local BEAM and
database evidence; credential expiry histories, packaged socket access, Peach
HTTP, guest TLS, native isolation and full project gates remain separate.
