# Enrico Git mirror architecture review — 2026-09-23

## Scope

Review of [ADR-0097](../decisions/0097-enrico-git-mirrors.md), the new Enrico
release, Marshall Ash catalog/Oban worker and browser, Overalls NixOS service,
secrets, firewall, updater and tests. The user authorized this service and its
deployment in a worktree. This review is based on the changed source and
executed checks, not the presence of dependencies alone.

## Findings and resolution

- **Resolved, high — unaudited cache deletion.** The first removal path deleted
  Enrico files before committing Marshall's audit and catalog change. A failed
  database transaction could have left a registered mirror with no cache.
  [Repository](../../../marshall/lib/marshall/enrico/repository.ex) now enters
  `removing`, [Oban](../../../marshall/lib/marshall/enrico/worker.ex) retries
  deletion, and the [catalog](../../../marshall/lib/marshall/enrico/catalog.ex)
  rechecks current state before every read. The removal request and final
  outcome use distinct append-only audit events. This implements ADR-0097's
  authority and recovery boundary.
- **Resolved, high — removal lost behind refresh uniqueness.** Oban initially
  treated refresh and removal for one repository as the same unique job. A
  removal requested during an active refresh could wait until the next hourly
  scan, and a future refresh deadline could exclude it even then. The worker
  now uses distinct operation keys and reconciles every `removing` repository
  independently of its refresh deadline.
- **Resolved, high — cache ahead of durable publication.** The initial viewer
  used Enrico's mutable `HEAD` while Marshall's refresh outcome was still
  pending. Enrico now reports the resolved commit SHA, and the
  [viewer](../../../marshall/lib/marshall_web/live/git_live.ex) defaults to
  Marshall's recorded SHA. An interrupted refresh therefore keeps the previous
  default tree visible. Explicit branch and tag views remain live Git refs, as
  shown in the interface.
- **Resolved, high — force-pushed head could be pruned.** The mirror now pins
  every observed default head under internal refs before updating upstream
  refs, and disables automatic Git maintenance. The machine test force-pushes
  an unrelated history, runs `git gc --prune=now` and reads the older SHA.
- **Resolved, medium — cache capacity escape.** The production
  [NixOS module](../../../nix/domains/system/enrico.nix) creates a service-owned ZFS
  dataset, sets `refquota=100G` and checks its mounted state before launch.
  A failed mount no longer permits writes into an unbounded parent directory.
  Reads have bounded Git operation time, output, body size and path scans.
- **Resolved, medium — source and auth boundary.** The
  [Git runner](../../../enrico/lib/enrico/git.ex) constructs fixed GitHub HTTPS
  URLs, uses argument vectors and disables credential helpers/redirects. The
  [API](../../../enrico/lib/enrico/http.ex) requires a dedicated token over a
  private TLS listener. Marshall checks current registration, login, admin
  authority and passkey elevation at its boundary.
- **Live rollout finding, high — socket reactivation interrupted the updater.**
  Overalls stayed at revision `2a998bf8` after a candidate activation failed
  on 2026-09-23. The fleet relay socket reactivated its service while the
  updater stopped consumers; systemd canceled the stop transaction. Lilly was
  left inactive and was restored manually. The updater now quiesces declared
  sockets before consumers, restores previously active roles after failure and
  restarts sockets after activation. The Overalls declaration names the fleet
  relay socket. The changed updater machine test exercises continuous socket
  traffic through a switch and failure path. The corrected runtime activated
  revision `3a5ae1a1` on Overalls; the updater recorded it as healthy.
- **Live Nixpkgs finding, high — the private TLS certificate was rejected by
  Marshall.** Production initially used the same self-signed Ed25519 certificate
  as server leaf and trust anchor. The release's Req transport rejected it as
  `selfsigned_peer`; three automatic attempts failed before Git fetching began.
  The certificate is now a CA-signed P-256 server leaf with a separate CA,
  hostname SAN and server authentication usage. The API token is preserved.
  Marshall classifies TLS and timeout failures into fixed audit and event
  reasons, and its administrator page exposes the reason. The service Git
  timeout, status wait and Oban job are extended to 60, 65 and 70 minutes for
  an initial Nixpkgs clone.
- **Live Nixpkgs finding, high — the 2 GiB service limit killed Git.** After
  TLS repair, Enrico began cloning Nixpkgs but the memory cgroup killed
  `index-pack` at its 2 GiB limit while the cache held 2.5 GiB. The service
  restarted, and Marshall's first polling request failed transiently; its
  retries then used new attempt IDs while Enrico was still busy. The live
  service limit was raised to 8 GiB without restarting the current clone.
  The shared Enrico NixOS module now makes that limit the fleet default, and Git pack work is
  constrained to two threads. Marshall retries transient status failures,
  resumes the previous attempt after a worker interruption, and records an
  abandoned attempt when Enrico reports it failed or missing.
- **Live Nixpkgs finding, high — a manual refresh overlapped the active job.**
  The previous 60-second Oban uniqueness window expired while Nixpkgs was
  still indexing. A manual refresh then enqueued another worker, replacing
  Marshall's attempt ID while Enrico retained its single active clone.
  Manual refresh now reports that the repository is already refreshing, and
  the uniqueness period spans the 70-minute job timeout. A regression test
  verifies that the rejected action adds no refresh-intent audit event.

## Verification

- Enrico `mix precommit` passed compiler, event catalog, formatter, tests and
  forced Dialyzer after the final recovery refinements.
- The packaged [Enrico NixOS machine test](../../../nix/verification/tests/machines/enrico-service/default.nix)
  passed verified HTTPS Git clone, token rejection, tree/blob reads, update and
  preservation of published content after source failure. The revised test
  also passed a force-push and pruning case. It uses a synthetic GitHub DNS/TLS
  fixture and a small repository.
- The existing auto-update and fleet-network NixOS machine checks passed.
  Overalls' deployable system closure built, and the encrypted secret
  inventory passed the recipient check.
- The revised auto-update NixOS machine check passed with the socket client
  active through a candidate switch and with service/socket restoration after
  a failed activation.
- Marshall's focused Ash state/auth and LiveView tests passed, including
  registration, manual refresh, removal intent and stale-read denial. The full
  Marshall precommit suite and forced Dialyzer passed after those code changes.
- `elixir scripts/check_adrs.exs`, code-contracts validation and Python
  ruff/ty gates passed for the changed tree.
- On Overalls, the updater recorded `3a5ae1a1` healthy. Enrico, its cache unit,
  Marshall, Lilly and the relay socket were active; the updater timer was
  restored. The `zroot/enrico` dataset was mounted at `/var/lib/enrico` with
  `refquota=100G`. Enrico's Unix readiness endpoint returned `ready=true`.
  Its HTTPS listener bound `10.90.0.1:5445` and rejected an unauthenticated
  request with HTTP 401 under the configured CA.
- After the certificate rotation, Overalls activated `a450cfda` healthy.
  The deployed Marshall release returned a verified `:not_found` for a cache
  before fetch, then Enrico cloned `github/nixos/nixpkgs` successfully under
  the live 8 GiB cgroup. The cache used 4.7 GiB and Marshall published
  `0fab6f88ef525e108dcf8645d8fe90a828a3a9d4`. The deployed client read
  21 root tree entries, including `flake.nix`, and a 5,200-byte `README.md`
  at that commit. The database phase was `ready` with a matching head.

## Remaining acceptance

The synthetic machine fixture does not exercise a repository near 100 GiB, cache pressure,
or a physical fleet
tunnel packet test. These are operational acceptance gaps, not evidence that
the implemented boundary is absent. The hourly job returns the first 100 due
repositories per tick; large catalogs need an observed throughput limit and a
cursor or batching policy. The 100 GiB cache has no automatic eviction policy;
an exhausted dataset causes refresh failure while the last published mirror
remains browsable. Branch and tag names move to newly fetched refs before
Marshall commits a refresh outcome; previous branch/tag names are not held as
an atomic published snapshot. Marshall's default view remains pinned to its
durable head SHA.
