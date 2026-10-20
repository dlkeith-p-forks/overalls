# Overalls service deployment review

Date: 2026-09-17

## Scope and architecture impact

The operator requested one Marshall, one Lilly and local PostgreSQL on overalls,
publicly named overalls.dev. ADR-0048 supersedes ADR-0029 and ADR-0043 while
preserving their rationale, custody, durability and host installation boundaries.
This is explicitly one physical failure domain.

## Findings and decisions

- The previous minimum of three declared replicas conflicts with the requested
  one-instance topology. Runtime/Nix validation now accepts an honest count of
  one, retaining TLS and the connection-budget formula.
- Local PostgreSQL must exist before the updater's first application migration.
  Bootstrap database/TLS/password units are deployed separately before roles.
- Public DNS now resolves overalls.dev to OVERALLS_PRIMARY_IPV4. The deployment uses
  HTTP-01 issuance for the public proxy and a private CA for verified local
  backend and database connections. Lilly uses the local backend on port 4443.
- Resend credentials are encrypted for the host and administrator recovery key.
  Verified TLS SMTP authentication succeeded on port 465; no email was sent.
  The configured sender is noreply@overalls.dev.

## Verification and remaining work

Marshall's one-replica runtime change passed its full precommit gate, including
tests and Dialyzer. Contract syntax and the 48-decision ADR structure/link check
passed. These checks do not establish physical service readiness.

Deployment completed on revision c88763edec864dab5bd989e8683a8a78c956ff90.
The exact published Nix deployment built successfully and the physical updater
reported healthy. PostgreSQL, marshall-overalls, lilly, haproxy and
overalls-smtprelay are active, with no failed systemd units.

The Marshall database role authenticated with verify-full and negotiated TLS
1.3. PostgreSQL reports localhost-only listeners, fsync=on,
full_page_writes=on and synchronous_commit=on. The updater ran the separate
migration before serving activation. Public / and /health/ready return HTTP 200;
the latter returns ok. The public certificate names overalls.dev and is issued
by Let's Encrypt.

Host 3d3fa366-fa82-46f2-96a1-dfff0bd3f609 is the only enrolled host. It reports
protocol v3, fresh inventory and execution_ready=true. The protected operator
command enabled scheduling only after these checks. Host verification preserves
the installation receipt, mirrored pool and dataset identities.

Initial issuance completed after the proxy exhausted its first startup retries;
resetting the failed publication/proxy units after issuance recovered HTTPS.
An initial image setting incorrectly named manifest.json instead of its containing
directory. Lilly rejected it before claiming ownership. The updater correctly
refused the missing ownership baseline. Restoring the last healthy configuration
with the same Marshall release allowed normal activation of the corrected image
directory. No database rollback, disk changes or fabricated ownership record was
used. A transient GitHub SSH timeout passed on retry.

No guest workload or actual email delivery was exercised in this deployment
acceptance. Off-host backups, restore drills and multi-host resilience remain
unverified; ADR-0048 remains partial for these operational gaps.

## Image catalog follow-up

The first user attempt to create a machine exposed a deployment acceptance gap:
Lilly advertised its verified installed image, but Marshall's compute_images
catalog was empty. Service readiness alone did not prove user-visible image
availability. The deployment now registers that same manifest through
Marshall.Compute.Images.register in an unprivileged, idempotent operator unit
before serving startup. It retains existing catalog state and verified runtime
database credentials. This implements the existing catalog policy without a new
schema or admission bypass. Revision fe30e45 deployed successfully: the catalog contains one enabled NixOS
image matching Lilly's advertised sha256:1c49a3303a0b155db98dfe05d30092ea71ac65c3420b83a600dca776ee5aea57.
Host execution readiness is true and both host and pool reports were two seconds
old at verification. No guest was created on behalf of the user.
