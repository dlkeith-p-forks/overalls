# Mila notifications architecture review

The change adds the `Marshall.Notifications` Ash domain (ADR-0225): Mila
devices bound to the registering SSH key, needs-input deliveries produced after
the outer planning commit, and a delivery worker that sends Susan (ADR-0224)
content-free, end-to-end encrypted pokes signed by a per-install Ed25519
identity. Authority stays in Marshall: Susan never receives routes, thread or
machine identifiers, names, emails or keys, and its origin is a compiled
constant with a `MIX_ENV=test`-only override.

Boundaries reviewed:

- **Domain ownership.** Notifications owns devices, deliveries and the install
  identity. It reads SSH keys, accounts and agent threads; SSH key archive and
  account deletion/retirement call its revocation functions inside their own
  transactions. No other domain writes notification rows.
- **Protocol.** `OverallsProtocol.PushPoke` implements the unchanged
  `push_pokes.json` vectors; `OverallsProtocol.SusanPoke` defines the canonical
  eight-member body and the domain-separated signature
  `"overalls-susan-poke-v1" || 0x00 || body`, pinned by
  `protocol/test/fixtures/susan_poke_request.json`. Porsche device commands
  are mutations with request ids and pinned receipts; the push key is only read
  from stdin and receipts keep its digest.
- **Persistence.** Partial unique identities fence one live device per user and
  X25519 key and one open delivery per device and collapse key. The push key and
  install seed are AshCloak-encrypted; PaperTrail ignores keys and routes.
  Terminal deliveries and versions are pruned after seven days.
- **Recovery.** Oban `:notifications` jobs are unique by delivery id with eight
  attempts; the `attempts` counter fences stale jobs; a reconciler re-enqueues
  rows without a job. 404/410 invalidates the device.
- **Operations.** `services.marshall.notifications.enable` reaches Marshall as
  `MARSHALL_NOTIFICATIONS_ENABLED` through both launch wrappers.

Implementation is partial: real Susan, APNs/FCM delivery and Mila-side
decryption are not exercised here.

## Recorded verification

All runs used the worktree `feat/mila-notify`; Marshall tests ran against a
private PostgreSQL. The machine was shared with several concurrent sessions,
so some unrelated timing-sensitive tests timed out.

- Protocol run before the trunk update (`mix test`): **395/398 passed**. Two
  failures are `OverallsProtocol.NativeAdmissionTest` freebsd/illumos tests,
  which also fail on the base commit `e4259258`; the third, a device command
  push-key length assertion, was fixed and the affected files rerun:
  Protocol focused rerun: **33/35 passed** (only the two pre-existing native
  admission failures).
- Protocol poke run: **13 passed** (`push_poke_test.exs`, `susan_poke_test.exs`).
- Protocol `mix compile --warnings-as-errors` and `mix dialyzer --force-check`
  passed before the trunk update.
- Notifications and contract run before the trunk update: **34/36 passed**; one
  failure was a mailbox assertion in the contract test, since fixed, and one a
  database checkout timeout under load.
- Focused Marshall run: **118/120 passed** (after the trunk update;
  notifications, contract, SSH and docs tests). Every notifications and contract test passed. The
  failures were the public docs title catalog check (fixed afterwards by
  adding the documentation catalog identities, not rerun) and a timeout in
  `GuestRosterMigrationHistoryTest`.
- Broader Marshall subset before the trunk update (agents, ssh, accounts,
  threads lifecycle, marshall_web): **679/710 passed**. The 31 failures are in
  code this change does not touch (machine and integration LiveViews missing
  `:labels`/`:comment`, Git settings on the account page, time-zone and executor
  Hegel cases) or are timeouts and Hegel `TooSlow` health checks under load.
- Covenant static check: **42/42** obligations covered, including
  `marshall.notifications` 6/6.
- Porsche run (`mix test`): **111 passed**.
- `push-notifications` NixOS machine test after the trunk update, built from
  source with KVM: all six subtests passed (`test script finished in 103.87s`):
  the serving wrapper carries the switch; Susan 503, 503, then 200 yields
  exactly one provider send; bodies are signed ciphertext only; 410 invalidates
  the device and later pokes are never sent; the journal holds no push key,
  ciphertext or route; and `notifications.enable = false` refuses registration.
  It ran before the documentation catalog edits, which do not change the paths
  it exercises.

Not run: Lilly consumer checks, Marshall and Porsche Dialyzer, `mix precommit`
in any project, and the HLDD checks (HLDD edits are handed off).
