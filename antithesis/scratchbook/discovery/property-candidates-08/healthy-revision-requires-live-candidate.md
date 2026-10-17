# healthy-revision-requires-live-candidate

Priority: P0. Confidence: high (source contract and exact code paths); hosted fault behavior untested. Focus: lifecycle upgrade.

## Claim and assertion

A newly recorded `lastHealthy` revision must identify the exact active Nix closure after current candidate secret preparation and two successful bounded rounds of enabled role health. Proposed missing `Always`: **`lifecycle.update_healthy_requires_active_closure_current_secrets_and_role_health`**. This is safety: check every transition of `lastHealthy` to a new revision, rather than interpreting a failed run as success. A distinct missing `Reachable`: **`lifecycle.update_identical_closure_current_secrets_verified`** at the successful identical-closure branch after staged secret comparison and live verification; this guides the subtle fast path, without asserting that a violation is reached.

## Evidence and failure history

`nix/domains/system/auto-update/CONTRACTS` says exact candidate closure, candidate secrets and active preparation units must precede `lastHealthy`. `runtime.py:341-388` snapshots and validates encrypted candidate sources into private staging; `:390-405` compares staged with live bytes. `:437-542` preflights compatibility before `:542-571` launches the candidate migrator. `:580-662` stops socket activators, consumers and secret units, switches the exact closure, then starts candidate secret units before consumers. `:746-924` checks active closure, active secret and role units, affirmative status endpoints and two successful checks inside `healthTimeout`; `:926-940` writes `lastHealthy`. `:985-1012` takes the identical closure path only after stage, byte comparison and verify. `:958-984` has already-healthy short circuits, so the oracle must target a *new* healthy advancement, not recurring health status. ADR-0036 lines 26-47, 78-96 claims pre-switch migration and no automatic schema rollback. `nix/verification/tests/machines/fleet/scenarios/updates.py:1-24,26-48` checks real release/secret upgrades and unchanged guest process snapshots. Existing tests are presence/recorded evidence, not this Antithesis assertion.

Failure history to explore: kill updater before/after staged secret snapshot, migrator exit, consumer stop, secret-unit stop, Nix switch, secret-unit restart, first and second health checks, and healthy-state write; deliver different encrypted secret bytes at the same Git revision; fail one enabled Audi/Porsche/Enrico/Ziggy role endpoint while systemd stays active. A partial switch is not itself a successful upgrade.

## Independent oracle and workload

Use the real updater, systemd, candidate Git closure and credential preparation in a native NixOS or owned TCG machine. Capture old/new revision, `readlink -f /run/current-system`, manifest equality, candidate secret descriptor IDs and live secret-file digests inside a privileged oracle that emits only comparisons (never secret bytes), `systemctl is-active` for candidate secret units, and the actual private/HTTPS status responses. Watch atomic `state.json` writes or poll revision changes; for every *new* `lastHealthy`, require exact closure and current secret digest, and independently probe enabled services twice before accepting. Inject failures and then heal; do not equate an updater timeout or stale prior `lastHealthy` with rejection of an uncertain switch.

Configured limit menu: `healthTimeout` accepts 10-1800 s (`default.nix:139`), so use 10, 120 default, 1800 only for a targeted slow migrator; status response cap 4096 bytes, Porsche/Audi private socket eight-second cap (`runtime.py:880-912`); one status role absent, malformed, negative, and stale socket; one versus all secret units; identical versus different active closure and secret bytes.

## Branch/replay guidance and scope

SUT-side instrumentation at `runtime.py:1002` (identical closure match), `:649-651` (nonzero switch but exact active closure), `:919-924` (first/second health round), and `:926-940` (durable healthy write) should report only revision/closure hashes and closed outcome codes. All proposed Antithesis assertions are **missing** per `antithesis/scratchbook/existing-assertions.md`; operational JSON events are not assertions. A hosted service-only composition cannot run native NixOS activation and secret-unit ordering; use native/TCG evidence and keep any hosted approximation explicitly weaker. No diagnostic-delivery condition belongs in the gate under ADR-0149.

Open questions: None after the source inspection above.
