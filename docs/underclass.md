# Underclass fleet service

Every current enrolled production host runs its own independent
[Underclass](https://github.com/ghuntley/underclass) subscription pool. Overalls
and Dungarees do not replicate accounts, SQLite state, sticky bindings or tokens.
Onboard provider accounts separately on each host and choose the desired host in
each client configuration.
Future hosts opt in by declaring a host-specific `NAME-underclass` encrypted
document; generic enrollment and base/recovery configurations remain independent.

## Access

Underclass listens only on `127.0.0.1:8080`. `underclass-tailscale-serve.service`
publishes that origin as HTTPS on the host's MagicDNS name. Tailscale Serve must
be enabled for the tailnet, both hosts must be enrolled, and tailnet ACLs must
grant the intended operators and clients access. Funnel is not used. Serve stays
in the foreground under systemd supervision, so publication-process failure
changes unit health and triggers a restart instead of leaving a stale active unit.

Tailnet identity is a network admission control, not application authorization.
Clients still send the host-specific `UNDERCLASS_PROXY_KEY` to `/v1/*`; the web
UI and `/admin/api/*` require that host's `UNDERCLASS_UI_TOKEN`.

The encrypted documents are `overalls-underclass` and
`dungarees-underclass`. Recover a document to a private file outside the checkout
with the ordinary `nix run .#secrets -- decrypt ...` workflow in
[fleet-users.md](fleet-users.md). Never put either value in a command argument,
Nix expression, issue, or diagnostic output.

## Onboarding

1. Open the selected host's Tailscale Serve HTTPS URL.
2. Enter that host's admin token.
3. Add Codex and/or Copilot accounts through the device flow.
4. Repeat on the other host if both independent pools need that account.
5. Configure clients with that host's HTTPS `/v1` URL and proxy key.

The account database is `/var/lib/underclass/pool.db`, mode `0700` under a
systemd dynamic user. It contains plaintext OAuth credentials. Underclass source
is pinned to an immutable revision, and that revision does not emit proxy/admin
tokens during startup.
Durable sticky bindings use the same 24-hour expiry and 10,000-entry cap as the
in-memory pool; pruning runs transactionally at startup, periodically and after
binding persistence.

The pinned upstream revision enables automatic Codex banked-reset redemption by
default. When a live request finds every enabled Codex account unavailable, it
may spend one available reset credit and verify recovery before serving through
that account. The pending attempt is kept in the host-local database for retry
with the same idempotency key. A host configuration can disable redemption with
`systemd.services.underclass.environment.UNDERCLASS_AUTO_CODEX_RESETS = "false";`.

Codex quota errors now prefer the later valid deadline from the upstream error
and `Retry-After`. A verified exhausted-window usage poll can extend a cooling
deadline, while an explicit allowed result readmits the account. When no usable
deadline is available, the configured cooldown remains the fallback.

## Operations and failure behavior

Revision `8c1a38c` retains the existing refresh-token rotation and rotates stored
Codex refresh tokens after 24 hours,
checking at startup and every 15 minutes. Rotation preserves account health and
quota cooldowns, including on failure; failed attempts retry on a later tick.
Copilot tokens are excluded. Opening an older database adds
`accounts.token_refreshed_at` with a zero default, making existing Codex tokens
due on the first pass. Successful refreshes persist the new token and timestamp
together; an older backup can contain an invalidated refresh token.

Upstream HTTP 401 or 403 triggers one forced refresh and same-account retry per
request before authentication failure and failover. An administrator can use
**Enable** to readmit an `auth_error` account or **Re-login** to replace its
credentials. Enable preserves an account's existing quota cooldown.
These changes have source review only in this pin update; tests were skipped
at the user's request, and live provider recovery remains unverified.

Revision `d0cb274` added manual redemption of one banked Codex reset
credit. Use **Use reset** on a Codex account row in the admin page, or run
`underclass reset <label-or-id>` on the host; both call
`POST /admin/api/accounts/{id}/reset` behind the admin token. The command
resolves the admin token like `utop`; with `--url` it requires
`UNDERCLASS_UI_TOKEN` and never sends a database token to a remote host.
Without `--force` the proxy refuses with HTTP 409 when upstream reports the
account is not rate limited or when a reset already redeemed for this outage has
not restored usage; a missing credit or a non-Codex account is never
overridable. Redemption reuses the automatic path's idempotency key and readmits
the account only after upstream confirms. The default catalog adds `gpt-6-sol`,
and usage accounting treats `"stream": true` requests as streaming. These
changes have source review and an offline package build only; tests were not
run for this pin update.

Revision `8c1a38c` records stream outcomes and sanitized upstream error codes for
completed proxy bodies. It exposes long-range request, token, session,
concurrency, outcome, capacity and policy statistics through
`GET /admin/api/stats` and `underclass stats`. The endpoint and event-import
route remain behind the administrator token. Statistics retain raw rows and
daily rollups for 730 days by default; minute and hour queries have bounded
windows, and old rows are pruned by the service. Prompts, cache keys,
credentials and upstream error text are not retained. This pin has source
review and an offline package build only; tests were not run.

Use `systemctl status underclass underclass-tailscale-serve` and
`tailscale serve status` for bounded status checks. Restarting Underclass retains
the local database. Failure of either service is reported by fleet monitoring and
deployment health, but does not stop Marshall, Lilly, guests, or the other host's
pool.

When fleet OpenTelemetry is enabled, `underclass-monitor-probe.service` checks
the read-only local monitor socket every 15 seconds. Its fixed readiness gauge
feeds a private Grafana candidate for both hosts. A failed monitor check is zero;
missing probe or collector samples make the candidate unknown. This probes the
local SQLite and monitor path only. It does not exercise Tailscale, proxy bearer
authorization or a live provider request.

Proxy request accounting is a private SQLite journal,
`/var/lib/underclass/slo-totals.sqlite`, holding one aggregate totals record and
pending admission identities only. Its single duration histogram has fifteen
finite bounds from 10 ms to 24 hours. Restart turns each pending admission into
one failure with unknown duration; no provider request is replayed. A separate
exporter user reads only the group-readable `/run/underclass/slo/slo.json`
snapshot. The retired seven-bound `slo.sqlite` is never read; an operator removes
it in a recorded maintenance window.

The enabled host also has `underclass` and `utop` on its PATH. Local `utop`
reads a limited monitor snapshot through `/run/underclass/monitor.sock` without
an admin token. Any local host user can read account labels, IDs, quotas, model
names and usage through that socket; it exposes no account controls, credentials,
full prompts or cache keys. `utop --url` selects another host's tailnet HTTPS
endpoint and still requires that host's `UNDERCLASS_UI_TOKEN`. The service's
private environment file and database are not exposed to interactive users.

There is no automatic cross-host failover. A client may be configured manually
for the other host, but its account set, quota health and sticky sessions differ.

Production host backups remain disabled. The backup inventory includes
`/var/lib/underclass` for future activation, but until encrypted backups and an
isolated restore are verified, loss of a host database requires provider
re-onboarding and can invalidate rotated refresh tokens. No recovery or
availability claim is made for this state.

## Live acceptance

Before relying on either endpoint, verify on both physical hosts:

1. the node is joined to the intended tailnet;
2. MagicDNS and tailnet HTTPS certificates are enabled;
3. no conflicting Tailscale Serve root exists;
4. the HTTPS URL is unreachable outside the tailnet;
5. missing/wrong Underclass bearer tokens are rejected;
6. each host sees only its own onboarded account set.

Local NixOS tests use synthetic keys and no public provider accounts. They do not
establish live tailnet policy, provider acceptance, subscription terms, fleet
throughput or host-failure recovery.
