# Public Grafana access review

## Architecture and contracts

ADR-0137 amends ADR-0132's operator access boundary with authenticated public
HTTPS on Overalls port 3443. ADR-0075/0091's perimeter ownership stays intact:
ordinary service openings cannot bypass it. The public frontend reuses the
validated runtime certificate and sanitized HAProxy log format. Forwarded
headers are replaced; foreign hosts refuse. Credentials stay in Grafana's
private state and no new application or receiver is introduced.

Semantic contract review covers repository secret diagnostics and decision
evidence, module runtime-secret and IPv4 rules, proxy reload/logging, destination
firewall grants, and isolated native fixtures. Grafana remains responsible for
login; Marshall users gain no new authority. Its frontend name stays outside the
Marshall SLI selector. A shared proxy or certificate outage affects both paths.

## Verification

The final configuration check passed in **81 seconds**, archive
`1790989474957-3463288-0.jsonl`, log `/tmp/overalls-public-grafana-eval-final2.log`.
It covers twelve generated ports under both firewall backends, enabled-role
opt-out, standalone firewall composition, invalid prerequisites, zero/conflicting
ports, SSH and socket conflicts, authentication and loopback settings. These
are generated Nix evaluation cases, not an application property framework or
native network evidence. The native check passed overall in **129 seconds**, with **84.52 seconds**
of script execution, archive `1790989689559-3569570-0.jsonl`, log
`/tmp/overalls-public-grafana-native.log`. An untrusted client verified the
disposable certificate, reached health and the authenticated 57-panel dashboard,
completed a real Grafana WebSocket upgrade, refused anonymous/wrong-password
operator reads and foreign Host requests, and could not reach loopback Grafana,
Prometheus, Tempo or an undeclared port. Validated HAProxy reload retained HTTPS.
The health check explicitly sends the configured Host to match Grafana domain
enforcement. Production activation and external reachability remain pending. Test fixtures use generated
certificates and isolated accounts; they do not prove production TLS, seven-day
history or external alert delivery. No deployment claim is made yet.

Moving main `b49db79e` was integrated without production source conflicts. Both
review entries and stricter distributed-race oracle evidence are preserved.
Only review-index and source-receipt conflicts required manual reconciliation.
The existing public certificate was inspected as `overalls.dev`, Let’s Encrypt
YE2, valid September 22 through December 21, 2026; this is certificate metadata
inspection, not new endpoint reachability acceptance.

## Production startup correction

The first activation of `d651c460` stopped HAProxy before binding public HTTPS:
`publish.py` required exactly one certificate reference, while Marshall plus
Grafana produce two. The corrected bounded validator permits one or two and
replaces every reference before checking the complete candidate configuration.
Trust, hostname, private custody, lifetime and matching-key checks remain intact.
A temporary runtime service override restored HAProxy using this corrected
validator; verified HTTPS `/login` returned HTTP 200. This is an operational
observation, not a new automated test result. No test suite was run at the user's
request. Permanent NixOS activation and removal of the recovery override follow.
