# Mila client commands: threads, terminals, web and watch (2026-10-18)

Scope: [ADR-0222](../decisions/0222-porsche-client-commands.md), with
[ADR-0220](../decisions/0220-mila-client-over-porsche-ssh.md),
[ADR-0221](../decisions/0221-canonical-app-routes.md) and
[ADR-0046](../decisions/0046-porsche-ssh-management.md). Reviewed against the
uncommitted working tree on branch `feat/mila-commands`, first on base
`e4259258` and then reapplied on the integration commit `8e67caab`.

## Findings

1. **Boundary:** No new Ash domain. `Marshall.Threads.ReadMarker` joins the
   Threads domain. Porsche gains no authority: every command still runs
   through Marshall's session authority and the owning domain action as the
   SSH actor.
2. **Protocol:** All 15 commands use the shared parser and catalog. The Dart
   encoder mirrors the canonical line form. Prompt, answer and revision text
   is accepted only as a stdin payload of at most 64 KiB, never as a
   command-line option.
3. **Receipts and audit:** Mutations pin `ssh_requests` receipts. Payloads are
   stored only as SHA-256 digests, and the new `ssh_key_id` column records
   which SSH key submitted the request. The channel is implicit, because
   `ssh_requests` rows come only from Porsche. These receipts are not shown in
   `/admin/audit` (gap).
4. **Terminal commands:** The terminal domain commits its opening intent
   before it dispatches to the guest, so terminal commands authorize and check
   replay first, then run the domain action, then pin the receipt. `terminal
   new` derives its opening id from the account and request id, so a retry
   reuses the same shell. No terminal tickets are issued over SSH.
5. **Watch authority:** `porsche.watch_subscribe` authorizes every named
   machine and thread, and is repeated on every 15-second heartbeat. Porsche's
   gateway binding now subscribes to all `:thread`, `:terminal_session` and
   `:ssh_session` hints. The trusted gateway therefore sees change identifiers
   across accounts, but never content. A hint never confers authority.
6. **Concurrency:** Read markers take an advisory transaction lock per reader
   and transcript, and never move backwards. `web set` relies on Ingress's
   VM-locked `policy_revision` comparison.
7. **Observability:** New events carry only enum or integer metadata:
   `ssh.watch_subscription_refused{reason}`, `porsche.watch_opened`,
   `porsche.watch_closed{reason}` and `porsche.stdin_payload_rejected{reason}`.
8. **Gap: committed hints:** Sandboxed tests never commit `pg_notify`, so
   hint delivery from a committed thread change to a watch is untested. The
   `porsche-threads` fleet machine test is written but has not run.

## Verification runs

Recorded on base `e4259258` plus this change, before the trunk reapply:

- Protocol client-command tests: **27 passed** (4 files, including Hegel
  properties). Full protocol suite: 390/392; the two failures were
  `NativeAdmissionTest` image contexts, unrelated to this change.
- Marshall client commands, approval page, Porsche service and real SSH
  transport: client commands **8 passed**; transport **8 passed**; together
  with approval and Porsche bind tests **15 passed**.
- Porsche full suite: **119 passed** after updating the boot probes for the
  new `Porsche.Watchers` child.
- Mila core: **57 passed**; `dart analyze --fatal-infos` clean.
- Porsche Dialyzer (`--force-check`) and protocol Dialyzer passed. Covenant
  static checks passed in protocol and Porsche.

After the reapply on `8e67caab`:

- Marshall targeted run (client commands, approval page, Porsche bind, SSH
  transport and SSH commands): **53 passed**.
- Protocol full suite: **396 passed**.
- Porsche full suite: 120/121. The one failure was a broken `.pot` merge,
  which was then regenerated; that suite has not been re-run since.

Not run: the full Marshall suite, Marshall Dialyzer, Lilly tests and
Dialyzer, and the `porsche-threads` machine test.
