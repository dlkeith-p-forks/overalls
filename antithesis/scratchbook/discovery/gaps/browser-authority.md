---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
---

# G1 browser entry and administrative authority gap

This is a repository-only candidate handoff. It changes no production code, catalog entry, topology or test. The source and ADRs state intended behavior; no new execution is claimed. The current catalog has no browser login, remembered-cookie, or Control room admin mutation property. Its nearest rows, `current-membership-gates-new-private-web`, `control-bound-credential-revalidated`, and `guest-identity-never-transfers-on-email-reuse`, begin after browser login or concern a different credential/identity. The fresh `existing-assertions.md` scan reports no Antithesis SDK assertion calls. The evaluation independently identifies G1 in `evaluation/coverage-balance.md:54-74` and `evaluation/wildcard.md:36-68`; neither evaluation proves a defect.

| Candidate | Type / priority / confidence | Unique primary literal SDK message | Independent witness |
| --- | --- | --- | --- |
| [magic-link-preview-post-mfa-boundary](browser-authority/magic-link-preview-post-mfa-boundary.md) | Safety `Always` / P0 / high | **Magic-link preview and pending MFA cannot grant browser work authority** | Local SMTP accept ledger plus token/login/verification rows and authenticated browser HTTP |
| [remembered-cookie-revocation-cross-replica](browser-authority/remembered-cookie-revocation-cross-replica.md) | Safety `Always` / P0 / high | **Revoked remembered cookie cannot mint or use browser authority across Marshall replicas** | PostgreSQL token/VM admission rows plus two browser sessions pinned to distinct Marshall replicas |
| [stale-admin-tab-current-mutation-authority](browser-authority/stale-admin-tab-current-mutation-authority.md) | Safety `Always` / P0 / high | **Stale Control room tab cannot commit an admin mutation after authority withdrawal** | Target account state, admin audit/outbox/token rows, and authenticated LiveView event on second replica |

For each `Always`, sample only after a definite revocation or refusal linearization point and reconcile a timed-out mutation by querying committed rows. Add separate, unique `Reachable` or `Sometimes` anchors for successful POST/MFA, remembered exchange and an actually refused stale event; those are search guidance, not substitutes for the safety check. Do not assert inbox delivery or exactly-once SMTP. Source `DeliverAuthEmail.send_bounded/3` uses a fixed Message-ID but explicitly permits uncertain acceptance after ACK/commit loss (`marshall/lib/marshall/accounts/deliver_auth_email.ex:103-151`); the browser request callback always gives generic feedback (`marshall/lib/marshall_web/controllers/auth_controller.ex:111-115`).

The focused `browser-authority` template selects one shared writable PostgreSQL, **two independent source-built Marshall release processes with distinct HTTP/LiveView sockets and Repo pools**, one fixture-owned local SMTP server with an immutable DATA acceptance ledger, and one typed browser/HTTP workload. Configure a shared signing secret, endpoint origin and WebAuthn RP identity; pin each browser context to a named replica while preserving actual CSRF, session and LiveView traffic. Read only synthetic local mail; keep token-bearing URLs and cookies out of diagnostics. This template can establish browser/account authority and committed admission effects. A guest nonce requires a separately selected real guest plus its access gateway; neither a DB row nor a canned response establishes guest execution or private ingress. The user-facing `access`/`guest-journey` templates may compose that variant, but the safety core need not boot a guest.

Existing evidence is scoped: `marshall/test/marshall_web/magic_link_flow_test.exs:75-137`, `remember_me_login_test.exs:14-123`, `marshall/test/marshall/accounts/admin_account_history_test.exs:24-79`, `admin_account_distributed_test.exs:10-116`, and `nix/verification/tests/machines/mfa-login/browser.py:175-345` exercise parts of these contracts. They are source-level test presence and historical scenario evidence, not a current Antithesis baseline. ADR-0123, ADR-0131, ADR-0065 and ADR-0022 carry the intended browser and admin rules. No architecture decision changes in this discovery edit; final-diff architecture impact is documentation of a missing verification property only. HLDD behavior/configuration/protocol/operations are unchanged, so there is no HLDD content impact.

## Investigation Log

- **Catalog duplication:** Searched all 75 canonical catalog headings and browser/auth terms in `property-catalog.md`; read nearest private-web and credential rows. None names magic-link GET/POST, remember exchange/revocation, or stale Control room event authority. The proposed oracles differ from gateway lease and machine/service Control credential checks.
- **Source and contract status:** Read ancestor `CONTRACTS` plus `marshall/lib/marshall/accounts/CONTRACTS` and `marshall/lib/marshall_web/CONTRACTS`, relevant annotated declarations, ADR-0123/0131/0065/0022, and current source. These are requirements and implementation mechanisms, not proof that the candidates pass under faults.
- **Existing instrumentation:** Read `existing-assertions.md`; it reports zero direct SDK callsites at this snapshot. All primary messages above are planned and missing.
- **Open fixture questions:** A browser runner must demonstrate an actual auto-submitting JavaScript visit and separately suppress JavaScript for preview GET. The hosted SMTP fixture must expose an immutable acceptance ledger and controlled DATA ACK loss. The exact Antithesis tenant fault set and hosted persistent-volume semantics remain unknown; report any unexercised schedule instead of converting missing fault injection into a pass.
