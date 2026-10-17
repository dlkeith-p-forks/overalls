# Review: fleet diagnostic log store and Control room viewer (2026-09-26)

Scope: implementation of [ADR-0127](../decisions/0127-fleet-log-store-viewer.md) —
a VictoriaLogs diagnostic store on the control-plane host, a path-scoped
authenticated fleet entry over the WireGuard fleet network, fleet-wide Fluent Bit
delivery of reviewed envelope sources, a read-only Marshall store client, and the
`/admin/logs` Control-room view for administrators and read-only administrators.

## Decisions exercised

- ADR-0127 (accepted): terminal destination, not a relay; WG-only listener;
  path-scoped insert/reader credentials; dedicated log-store CA in recovery-only
  custody; producer sources permanently exclude `audit`, `firecracker` and guest
  content; viewer stays read-only under Cedar `admin_read`.
- ADR-0042 custody preserved: per-host collectors remain host-local authority;
  bounded queues bridge store outages; delivery never authorizes domain actions;
  restricted evidence classes stay out of the destination.

## Evidence executed

- **Local integration spike (recorded, disposable):** pinned Fluent Bit 5.0.7
  `opentelemetry` output with custom `logs_uri`
  (`/insert/opentelemetry/v1/logs?_msg_field=payload.message,payload`) and basic
  auth into VictoriaLogs 1.52.0 from pinned nixpkgs; LogsQL text search on the
  mapped message and field-exact filters on flattened envelope attributes passed;
  the final entry template (HAProxy ACLs) accepted insert traffic and refused
  all four wrong-authority combinations with 401 and an untrusted-CA TLS failure.
- **Application tests:** `store tests 10 passed (2 properties, 8 tests)` and
  `viewer tests 3 passed` via
  `mix test test/marshall/logs/store_test.exs test/marshall_web/admin_logs_live_test.exs`
  (13 passed total: 2 properties, 11 tests). Property runs pin LogsQL quoting
  immunity for arbitrary text and fail-closed enum rejection; fixed tests pin
  duplicate absorption on envelope `event_id`, response narrowing/bounds, the
  reader-credential header, error taxonomy and LiveView authorization, filters,
  tail and halted unknown events.
- **Native machine evidence:** `checks.x86_64-linux.log-store built successfully`
  (`nix build .#checks.x86_64-linux.log-store`, SUCCESS in 43s): a real journald
  event on a worker host flowed through journal capture, `normalize.lua`
  classification, verified TLS with a committed CA and host SNI, the
  authenticated fleet entry and VictoriaLogs; exact wrong-credential and
  missing-auth 401s passed; an unverified CA path failed; the runtime collector
  configuration stayed 0600 with credentials injected at runtime (descriptor
  carries `_credential_files` paths only); entry-stop outage backfilled.
- **Static gates:** `scripts/check_adrs.exs` passed with ADR-0127 indexed;
  `scripts/hldd_views.exs --write` regenerated placement including
  `kittensLogging` (both hosts) and `kittensLogStore` (overalls);
  `nix run .#secrets -- check` validated recipients/metadata for 40 documents
  including `overalls-logstore`, `dungarees-logstore` and recovery-only
  `logstore-ca-recovery`.

## Limits and open gaps

- No native browser Control-room journey over the real Marshall release yet;
  LiveView evidence is application-level with a stubbed store transport.
- Production rollout, log-store CA rotation rehearsal, multi-host fleet mixing
  and sustained load are not yet exercised; queue budgets are asserted at
  evaluation but not measured under volume.
- Duplicate absorption after real queue backfill is proven at the client unit
  level (event_id dedup), not observed in a native repeated-delivery window.
- The `payload.message,payload` `_msg_field` fallback ordering is proven for
  decoded JSON payloads; raw-string payload mapping to `_msg` rides the VictoriaLogs
  comma-fallback and is asserted in the machine test text search only indirectly.

## Production activation record (2026-09-27)

Merged as `e3f2a8fc`, fix chain `367f1105`/`1ae448c7`, deployed via the fleet
auto-updater from origin/main (`a4ce6c9e`). First activation surfaced two
fixture-invisible breakages before any log loss or restricted-evidence exposure:
Fluent Bit 5.0.7 YAML load rejects > ten conditional routes per input (the
journal reader now chunks at eight with distinct cursor databases; tail inputs
exist only for explicitly selected sources — the empty-route crash on overalls
also prevented a latent unrestricted-tail fallback onto default tag routing, so
the crash became the safe failure), and the upstream VictoriaLogs unit's
DynamicUser state-directory bind mount conflicts with the pre-mounted
`zroot/logstore` dataset (resolved with the dedicated static user and
dataset-owned mountpoint). Post-fix host checks: `victorialogs`,
`logstore-entry` and `kittens-logging` active on overalls and the collector
active on dungarees; live row queries over the reader credential return fleet
entries (dungarees/audi, overalls/marshall); insert credentials are refused on
`/select/*` (401); the public `/admin/logs` route answers 302 to anonymous
browsers. Production load, long-horizon retention and CA rotation remain
deployment-open.

## Secrets generated (this session)

A dedicated EC P-256 log-store CA (`logs.fleet.internal` leaf, 10-year horizon),
an insert and a reader credential; ciphertext delivered via the repo SecretSpec/SOPS
workflow (`nix run .#secrets -- encrypt <doc>`). Plaintext intermediates stayed in
0700 `/tmp/opencode/logstore-work` and hold no repository copies; the CA private key
lives only in the recovery-only `logstore-ca-recovery` ciphertext and that
directory, to be wiped after merge (see deployment notes).
