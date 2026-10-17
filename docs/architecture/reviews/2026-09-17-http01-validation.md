# HTTP-01 validation and three-frontend routing review

## Scope and architecture impact

ADR-0038 replaces the Route 53-only validation inherited through ADR-0036 from
ADR-0030. Other deployment/update decisions remain in force. ADR-0033 gains HTTP
acceptance coverage. The user selected HTTP-01 defaults, HTTP-only redirects,
three privately connected frontends and no backwards-compatibility requirement.
No application resource, database schema or protocol changes are part of this work.
Existing unrelated relocation work in the working tree is preserved.

## Findings and decisions

- **High, bootstrap dependency:** public HTTP runs separately from HTTPS and
  certificate publication. Its lookup process has no access to certificate keys.
  Issuance waits for HTTP ingress, with no reverse dependency on issuance.
- **High, validation routing:** multi-peer HAProxy retry counts do not guarantee
  visiting the owner. Direct concurrent lookup visits each configured responder
  at most once and cancels remaining work on success. No recursive forwarding,
  external redirects or caller-selected destinations are permitted.
- **High, explicit trust boundary:** private peers are trusted to validate the
  same hostname. RFC1918/ULA inputs and source-specific firewall rules prevent
  accidental public responder exposure by this module. Operators must not add
  broader independent firewall allowances or use an untrusted private network.
- **Medium, resource and diagnostic boundaries:** endpoint/overall deadlines,
  bounded bodies and active lookups constrain fan-out. Raw aiohttp and ACME logs
  are disabled; structured events omit challenge material. The pinned aiohttp
  dependency is isolated to the host lookup service.
- **Recovery:** existing persistent publication and proxy validation remain
  unchanged. Failed issuance cannot replace the published certificate; HTTP
  routing does not require sharing private keys between hosts.

## Validation

- Module configuration check passed, covering the HTTP default, DNS requirements,
  peer validation, port collisions, firewall opt-out and both firewall backends.
- Nine lookup tests passed against real local HTTP fixtures: all nine owner/ingress
  combinations, concurrency, malformed/oversized replies, redirect refusal,
  deadlines, cancellation, overload, unreachable peers and HTTP credential isolation.
- The HTTP machine suite passed in 218.92 seconds: each of three independent
  issuers validated through another frontend, simultaneous renewals retained
  WebSockets, failed validation preserved published certificates, peer recovery
  and source-specific firewall restrictions worked, publication retried a failed
  reload, and standalone loopback issuance required no AWS credentials. The final
  run with the corrected DNS answer-rotation counter also passed in 187.85 seconds
  (`yah46vq5jx12s5za222z416fwwyirzj6-vm-test-run-overalls-acme-http01.drv`).
- Route 53 regression passed in 184.77 seconds
  (`ajfvrq3dvm4dvv0aazwwas11mrnl4kr4-vm-test-run-overalls-acme-route53.drv`),
  including invalid certificate rejection, cached startup and reload recovery.
- Service-role regression passed in 127.12 seconds
  (`ijg67i4sn7dzh4mbnfa5k4pg9rxn850w-vm-test-run-overalls-service-roles.drv`).
- Full flake evaluation passed using an unstaged source snapshot. The pinned
  ADR checker and contract format/coverage gates passed. Contract review traced
  challenge selection, credential delivery, fixed responder destinations,
  cancellation, publication and shared fixture consumers; no mismatches remained
  in this scope. Application source was not changed by this work.

Initial machine attempts exposed missing builder KVM access and an inactive
test-only CA trust unit. Builder access was supplied for the runs; the driver now
explicitly starts trust after receiving the validator's public CA. The service-role
run used the local root builder with the required nested-KVM feature. The DNS
fixture's rotation counter was corrected during review. These failed attempts
are not counted as passing acceptance.

## Remaining acceptance

Production provider/network acceptance and large-fleet load remain separate.
IPv6 peers and nftables rules have evaluation coverage; runtime firewall tests
use IPv4 and iptables. All QEMU nodes share one physical failure domain. WebSocket checks exercise
Marshall transport heartbeats, not authenticated guest terminal sessions.
