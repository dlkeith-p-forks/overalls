# Architecture review: authenticated provisioner transport

Subsequent implementation: [capacity loop review](2026-09-15-capacity-loop.md)
records the now-tested automatic sampler, exclusive state ownership and durable
receipt. Findings below describe this earlier transport checkpoint.

## Scope and evidence

Reviewed new encrypted credentials, archived revocation, keyring handling,
durable session nonces, authenticated report/command transactions, the shared
protocol library and Lilly HTTPS client. Reviewed generated additive migrations,
internal Cedar action mappings, tests and staged/unstaged/untracked work. Existing
source relocation and unrelated application edits remain preserved.

## Affected decisions

ADR-0012 is accepted/partial within the user's implementation authorization.
ADRs 0002, 0003, 0004, 0006, 0009 and 0010 remain applicable; no accepted decision is
superseded. The overview and evidence now distinguish an actual transport
foundation from the still-missing autonomous provisioner vertical slice.

## Findings

1. **High — documented unimplemented requirement:**
   [Lilly client](../../../lilly/lib/lilly/control/client.ex) performs individual
   requests; no exclusive process ownership, continuous collector, durable
   receipt store or VM driver consumes commands. Hosts default disabled and
   user provisioning is not exposed. Complete those pieces and physical outcome
   reconciliation before claiming automated provisioning or one-second reporting.
2. **High — documented unimplemented requirement:** credentials are encrypted and
   revocable, but an operator CLI/private credential-file delivery and production
   secret-store/re-encryption/restore workflow remain open. The trusted
   [coordinator](../../../marshall/lib/marshall/compute/credentials.ex) is not an
   ordinary user API. Complete operational delivery before fleet enrollment.
3. **Medium — documented unimplemented requirement:** session tombstones and
   credential/audit records have no retention job. Retaining old nonces prevents
   delayed opens from acquiring fresh epochs; deletion requires a safe design.
   Poll load, DB connection budgets and whole-database HA failover still need
   workload measurements.
4. **Resolved implementation defects during review:** replaced the initial
   last-session-only design with durable nonce records, so old open retries
   cannot displace successors. Disabled automatic response decompression as well
   as bounding streamed bodies, covering compressed-response expansion. Reports
   now reject an inventory architecture that differs from the enrolled host.

## Verification performed

- Credential tests: encryption/decryption, inspection redaction, secret-free
  paper trails, archival/rotation/expiry, Cedar denial and retained reservations.
- Protocol properties: command/report round trips, bigint precision and arbitrary
  bytes; tests for versions, unknown fields, collection/depth limits and UUIDs.
- API tests: host scoping, idempotent opens, old-nonce rejection, null reports,
  receipt-only acknowledgements and rollback of reports on invalid receipt IDs.
- Real socket tests: trusted CA TLS succeeds, untrusted TLS fails, redirects are
  not followed, success/error responses are bounded and compressed input is not
  expanded. Certificates are explicitly public local test fixtures.
- Three independent BEAM nodes: duplicate opens share an epoch and every node
  observes revocation, retaining VM reservations. Existing admission races and
  failed-AshOban-insert rollback also pass. The deliberate DB failure emits its
  expected rollback diagnostic.
- All three `mix precommit` gates pass: Marshall 56 tests/6 properties, Lilly
  11 tests/3 properties, protocol 2 tests/3 properties (69 tests and 12 properties
  total). Compiler/format checks pass. Dialyzer has no new findings; Marshall
  retains the single documented upstream AshAuthenticationPhoenix typespec
  exclusion with unused-filter detection.
- The 12-record ADR check, schema codegen check and `git diff --check` pass.
  Original-file hashes differ only for the intended changes across this work;
  unrelated user modifications were preserved. Corrupt encrypted credential
  storage also returns a fixed 503 without ciphertext diagnostics.
- Lilly's production release was rebuilt and booted with its shared protocol and
  HTTPS client dependencies. Its autonomous report loop remains unconfigured.

## Follow-up

Implement the report collector and durable/exclusive Lilly loop, then the actual
VM driver, networking, lifecycle reconciliation and terminal access. Use a second
independent KVM host for cross-host isolation/recovery proof. Do not treat these
foundation tests as proof of production HA, 100-node scale or VM execution.
