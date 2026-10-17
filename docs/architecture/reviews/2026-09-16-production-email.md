# Production authentication email review

## Scope and architecture impact

ADR-0024 completes durable magic-link delivery within the Accounts domain using
an AshCloak outbox, AshOban jobs and authenticated SMTP with verified TLS.
ADRs 0008 and 0009 retain their identity and assurance requirements. Production
HTTPS configuration is reconciled with ADR-0012's direct-TLS policy. Lilly and
the shared protocol are unchanged. The user's instruction to implement the plan
authorizes this refinement; no accepted rationale is superseded.

## Findings and resolution

- **High, corrected duplicate delivery:** a real three-node race initially
  submitted three messages for one outbox record. The installed AshOban worker
  reads with a lock before the action transaction, which did not serialize this
  side effect. The delivery change now requires a transaction and re-reads the
  record under `FOR UPDATE` inside it, holding that lock through SMTP and the
  status update. The regression counts actual SMTP messages, independently of
  worker return values. This was an implementation defect, not a changed design.
- **High, durable request acceptance:** recipient advisory locking, the database
  creation clock and a token fingerprint coordinate three nodes. Inserting the
  outbox and job is atomic; injected job insertion failure leaves neither, and
  a retry can enqueue. A one-minute cooldown suppresses repeated requests for
  the same case-insensitive address.
- **High, credential handling:** recipient/token payloads use AshCloak. Jobs
  contain identities only. Successful or obsolete deliveries clear ciphertext
  to SQL NULL; expiry cleanup physically deletes rows. There are no archival or
  audit copies of these transient credentials. Ordinary users cannot enqueue,
  read or deliver outbox records through Ash.
- **High, transport verification:** SMTP requires authenticated implicit TLS or
  mandatory STARTTLS, trusted certificate chain and hostname. MX lookup and
  library retries are disabled. A ten-second owning-task deadline closes stalled
  connections despite the dependency's much longer receive timeout. Relay
  acceptance cannot establish inbox placement. Lost acknowledgments or a failed
  commit after acceptance can still duplicate an email; retries retain the same
  token and Message-ID, and the token remains single-use.
- **High, corrected diagnostic disclosure:** magic-link tokens appear in URL
  paths. Parameter filtering alone did not protect HTTP/LiveView diagnostics.
  Authentication processes now carry a privacy tag, and a primary logger filter
  redacts their diagnostics. SMTP tasks redact arbitrary provider diagnostics;
  persisted job errors contain fixed text. HTTPS redirect logging is disabled
  because it runs before request tagging. External access logs remain an operator
  responsibility.
- **High, corrected TLS policy drift:** generated production configuration
  trusted arbitrary `X-Forwarded-Proto`. It now requires the connection's actual
  TLS scheme and does not exempt loopback Host headers. Tests exercise spoofed
  headers and token-bearing redirects. This restores ADR-0012's accepted policy.
- **Medium, corrected release build:** a clean production asset build failed
  because colocated CSS had not been generated. `assets.deploy` now compiles
  Marshall before bundling assets. This preserves the existing release contract.
- **Low, corrected type declaration:** `Ledger.lock!/2` already returned `nil`
  for a missing row, and credential coordinators already checked that case. Its
  typespec now includes `nil`, allowing Dialyzer to check the delivery action's
  missing-record handling accurately. Database behavior is unchanged.
- **Open operational acceptance:** SMTP credentials, sender-domain DNS, provider
  limits and controlled-inbox delivery must be verified for deployment. The
  recipient cooldown does not bound token generation or requests across arbitrary
  addresses. Two SMTP jobs per instance can each hold a database connection for
  the attempt deadline; combined fleet load needs measurement.

## Verification

Final Marshall `mix precommit` passed 186 cases (17 properties, 169 tests), six
browser-state checks, compiler warnings-as-errors and Dialyzer on Elixir 1.20.4 /
OTP 29.0.6. Dialyzer retains the existing single upstream typespec exclusion;
no new exclusions were added. Four unrelated opt-in host checks were excluded.
`mix ash.codegen --check` found no missing migration. Production assets and the
Marshall release built successfully. The ADR checker passes all 24 decisions.

The built release started against the test database with temporary keys and a
loopback SMTP configuration; checks confirmed its verified-TLS adapter, public
HTTPS URL, redirect policy and empty outbox. A second invocation without SMTP
credentials rejected startup with sanitized diagnostics. The smoke did not open
a public endpoint or send external mail. Logs in this development environment
are `/tmp/overalls-mail-verified.log` and `/tmp/overalls-mail-release-smoke.log`.

Focused checks use real loopback implicit-TLS/STARTTLS SMTP sockets and three
independent Marshall BEAM nodes sharing PostgreSQL. They cover certificate and
hostname rejection, downgrade refusal, a stalled connection closed by the total
deadline, sanitized provider failures, delivered-link single use, encrypted
storage/erasure, authorization, cooldown, transaction rollback and duplicate
delivery. The three-node regression failed with three actual SMTP messages before
the explicit action lock and passed with one afterward. Expected injected
Postgrex rollback diagnostics do not represent failing tests. No real provider or
recipient is used; no outbox fixtures remain in the database.

Review inspected touched source files, the generated outbox migration and tests.
The current repository has no commits and project paths are untracked, so a
historical Git diff is unavailable. Existing files and Git state are preserved.

## Follow-up

Complete real-provider deployment verification alongside protected enrollment,
drain/deployment workflows, operational key management, second-host execution,
terminal failover and representative fleet/load acceptance. These are remaining
platform requirements; completion of the email implementation does not establish
overall production readiness.

## Evidence

[Outbox](../../../marshall/lib/marshall/accounts/auth_email.ex),
[enqueue](../../../marshall/lib/marshall/accounts/auth_emails.ex),
[delivery](../../../marshall/lib/marshall/accounts/deliver_auth_email.ex),
[SMTP configuration](../../../marshall/lib/marshall/mailer/config.ex),
[log filter](../../../marshall/lib/marshall/mailer/log_filter.ex),
[request tagging](../../../marshall/lib/marshall_web/authentication_privacy.ex),
[database tests](../../../marshall/test/marshall/accounts/auth_emails_test.exs),
[SMTP tests](../../../marshall/test/marshall/mailer/smtp_test.exs),
[distributed regression](../../../marshall/test/marshall/compute/distributed_admission_test.exs),
[privacy tests](../../../marshall/test/marshall_web/authentication_privacy_test.exs),
[configuration tests](../../../marshall/test/marshall/mailer/config_test.exs),
[operator guide](../../operations/production-email.md).
