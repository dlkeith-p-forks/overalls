# Repository launch links (ADR-0128)

## Scope

This review covers new protocol, persistence, web-entry, vsock and guest-image
behavior for [ADR-0128](../decisions/0128-repository-launch-links.md).

- **Shared protocol:** `KittensProtocol.WorkspaceSource`, the optional Execution
  `workspace_source` field, Porsche `new --source`, and the `WorkspaceSource`
  lifecycle audit type.
- **Marshall:** the `Compute.WorkspaceSource` resource, admission and idempotency
  changes, the command snapshot, `/launch` LiveView and hook, and Porsche.
- **Lilly:** asynchronous boot-bound delivery on vsock port 1031, with its own
  journal.
- **Guests:** a standalone Rust `kittens-workspaced` receiver in the NixOS and
  Ubuntu images that runs plain `git`.
- **Lyra:** the `kittens open` verb.

## Architecture assessment

- **Domain boundaries.** Marshall owns the durable reference. Lilly only
  transports it, and the guest owns the clone. No host component runs git or
  touches guest disks, so repository content and GitHub availability stay
  outside host authority.
- **Protocol and rolling upgrade.** The field is optional and closed, and allowed
  only on `provision`/`start` for profiles with egress.
  - Older Lilly builds reject commands that carry it, so Lilly must be deployed
    before or together with Marshall. Each fleet host pulls the same revision
    and updates independently. During that window, only commands that carry a
    source can be rejected. Commands without a source are unchanged.
  - The `WorkspaceSource` audit type was added to the closed lifecycle audit
    set. Marshall maps it explicitly.
- **Persistence and idempotency.** The source row is written in the admission
  transaction and compared on replay. The same key with a different source is
  an `idempotency_conflict`. Clones never inherit a source.
- **Authorization.**
  - Launch uses the ordinary provision authority of the signed-in user or the
    Porsche key owner.
  - The profile is always OSS for links. Porsche refuses `--source` with
    profiles that have no egress.
  - Drive-by navigation is accepted: each fresh visit creates at most one
    default OSS VM owned by that user. This is recorded in the ADR
    consequences.
- **Isolation and fencing.**
  - Delivery re-checks the placement's current running authority and boot
    before every attempt and before it records a result.
  - The guest rejects any envelope whose placement, epoch or boot challenge
    differs from its own kernel command line, and answers only host CID 2.
  - Delivery is not linked to the executor and never delays running, fences a
    placement or affects readiness.
- **Guest execution.** git runs with an argument vector, never through a shell.
  The grammar forbids leading `-` in every value, and positional arguments
  follow `--`. The clone is built in a `.partial` directory and renamed, and a
  `done` marker prevents re-cloning.
- **Logging.** Marshall and Lilly events carry only VM, placement and reason
  identifiers. URLs, owners, repositories and refs are never logged.

## Verification

Results are recorded in the [evidence](#evidence) section below as the gates
run. A test that exists but has not been run is not claimed as passing.

## Evidence

| Gate | Result |
| --- | --- |
| `protocol` `mix precommit` | Passed (including Dialyzer). |
| `lilly` `mix precommit` | 431 tests (55 properties); Dialyzer clean. Intermittent timing failures in the unrelated Inception deadline tests (`PropagationTest`, `InceptionExchangeTest`) under heavy host load; clean reruns pass. |
| `marshall` `mix precommit` | 1262/1264 (153/153 properties); Dialyzer clean. `CredentialManagementBoundsTest` rename-bound also fails on the unmodified base; `CustomerIsolationTest` is flaky and passes alone. |
| `lyra` `cargo test` / clippy | All suites pass, including the Hegel receiver and `kittens open` state machines; clippy clean. |
| Nix `lyra`, `lyra` tests, `guest`, `ubuntu-guest`, `ubuntu-guest-unit`, `ubuntu-build-boundaries` | Built/passed. |
| `repository-launch` NixOS machine journey | Recorded native pass at `e2384877`: "test script finished in 446.89s", all ten subtests including shallow checkouts of all four ref forms, restart without re-clone, fresh-session launch and the `kittens open` CLI journey. |
| `repository-launch-ubuntu-fleet` | Recorded native pass at `e2384877`: "test script finished in 1023.01s", the same ten subtests on the Ubuntu guest image. |
| Production acceptance | `kittens open https://github.com/tastejs/todomvc` with the owner's credentials: machine running, SSH readiness wait, command ran in `/workspace/todomvc` at `ff43b02`, `shallow=true`, 4,495 files, 17 MB `.git`. Guest HTTPS through Brady returned 200 for every github.com address tried; SNI github.com to a non-GitHub address returned 502. |

| `default-oss-creation` (regression after the driver/setup split) | Recorded native pass at `21bdfb21`: "test script finished in 576.38s". |
| `brady-fleet` with host `src_valid_mark=1` | At `21bdfb21` the subtests through "real guest requests carry authoritative current VM and user attribution" pass, so intercepted guest traffic works under the Tailscale host setting. "Brady and Lilly restarts preserve guest lifetime and refresh flow attribution" then times out; it fails identically at the pre-change base `2b30e882`, so it is a pre-existing defect outside this change and remains open. |

### Defects found by native execution

- Lilly's durable command store treated `workspace_source` as placement
  identity, so a stop after a sourced provision was an `vm_identity_conflict`
  that fenced the host control channel. The reference is now operation metadata
  alongside `resize_id`/`clone_id`; a generated lifecycle property fails without
  the fix.
- Launch sizing used transient host inventory, so a replayed visit could drift
  to generic minima and be refused as an idempotency conflict. Sizing now uses
  the durable image record; a regression test fails without the fix.

### Production acceptance and shallow fetches

- After deployment, Porsche `new --source https://github.com/tastejs/todomvc`
  with the owner's registered key created a running OSS machine on the new
  guest image with the source pinned, and Lilly delivered the reference: the
  guest's `kittens-workspaced` reported `cloning` and retried.
- Every clone attempt then timed out because production OSS guests had no
  outbound web connectivity (TCP to any address on ports 80 and 443 timed out,
  including pre-existing machines). This change touched no network code.
- Root cause (Brady, ADR-0069): Lilly's router namespace sets strict
  `rp_filter=1` but inherited the host's `src_valid_mark=1`, which Tailscale
  sets on exit nodes. The reverse-path check then followed Brady's tproxy mark
  into its local-delivery table, so every intercepted SYN was dropped as a local
  source before reaching Brady (nft trace: accepted by `brady_intercept`, never
  reaching `input`; no socket state). Setting `src_valid_mark=0` in the
  namespace on overalls immediately restored guest HTTPS (github.com 200 in
  0.14 s); after restarting the guest unit, the todomvc VM cloned
  `tastejs/todomvc` to `/workspace/todomvc` at `ff43b02e` (4,495 files). Lilly now
  pins `src_valid_mark=0` with its other namespace sysctls, and the Brady fleet
  journey enables the host setting so the regression is covered. The live
  hotfix was applied only on overalls; dungarees was corrected by deployment
  (both namespaces verified at `src_valid_mark=0`).
- A second Brady defect then appeared as intermittent guest HTTPS failures
  (`reason: tls`): Brady required the SNI to resolve to the dialled IP in its
  own DNS view. The guest resolved github.com to 140.82.112.3 while Brady's
  resolvers returned 140.82.121.4/.3; forcing the guest to .121.4 succeeded and
  .112.x failed. HTTPS admission now relies on the pinned original IP plus
  upstream certificate verification (ADR-0069 correction); HTTP and TLS
  exception tunnels keep the DNS match.
- `kittens open` failed natively because it opened the interactive SSH session
  immediately after creation, before the new guest's SSH name and route had
  propagated (production showed the same transient "SSH proxy unavailable").
  It now probes with a non-interactive login for up to 180 s
  (`KITTENS_OPEN_READY_TIMEOUT`) before starting the session.
- The first clones were full clones. Measured against the real repository, a
  shallow default clone transfers about 9 MB instead of about 119 MB, so fetches
  are now shallow: `--depth 1` clones, exact-SHA and `pull/N/head` fetches into
  an empty repository, and a blobless partial clone for abbreviated SHAs. The
  machine fixture now serves smart HTTP (`git http-backend`) with
  `uploadpack.allowReachableSHA1InWant`, like GitHub, and asserts shallow
  checkouts.

## Remaining gaps

- Private repositories and non-GitHub hosts are out of scope.
- Real `github.com` through Brady TLS interception is production acceptance
  only. CI uses a local fake `github.com`.
