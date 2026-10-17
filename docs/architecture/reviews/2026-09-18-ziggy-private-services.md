# Ziggy private services implementation review

## Scope

New independent Ziggy inference release; Audi private DNS/TLS/PKI; Lilly
execution binding and local networking; Marshall Ash admission/accounting and
administrative monitoring; Nix service/secret/guest integration. Work is isolated
in `feat/ziggy-llm-proxy`. No production secrets, enrollment or deployment changed.
Relevant decisions: ADR-0063, ADR-0015, ADR-0047, ADR-0044, ADR-0042, ADR-0060,
ADR-0062. User authorization establishes ADR-0063's acceptance; implementation
remains partial until the separate end-to-end obligations are demonstrated.

## Boundary review

Provider calls use fixed verified TLS origins and preserve native bytes. Only
Audi's local Unix transport supplies Lilly's pre-NAT execution binding. Marshall
checks current host/VM/placement/epoch and completed generation before admission;
independent local and remote deadlines fence streaming. New guest starts and
relocation readiness require private services when enabled. Existing running
VMs remain independently supervised when services restart.

Provider secrets follow existing SOPS/SecretSpec publication and systemd
credentials. Runtime copies use 0700 directories and 0400 files, accommodating
systemd's 0440 credential snapshots without widening application readers.
Socket sharing uses distinct groups from credential custody. No intermediate
or root key enters Ziggy, Marshall, or the guest. Only the designated Audi issuer
receives the constrained intermediate; root custody is recovery-only.

Admission and completion are content-free, bounded and durable. Completion
retry cannot replay inference and repeated accounting cannot increment totals
again. Crash recovery records unknown usage. UI owner scope and administrator
scope remain distinct; sharing a VM gives no accounting access. Token prices
are estimates with version/digest provenance, not billing facts.

Monitoring extends the existing independently credentialed fleet collector.
Proxy probes are bounded and numeric, attributed to the service invocation and
physical host. Missing, reset or stale observations stay unknown. Historical
charts use the existing administrator-authorized Ash projection and retention;
monitoring never establishes execution authority.

## Findings and remaining acceptance

- **Resolved: runtime startup.** NixOS execution exposed systemd credential modes
  rejected by strict readers. Private runtime copies preserve the reader contract;
  separate socket groups preserve the intended service boundaries.
- **Resolved: stale caller identity.** Audi rechecks binding after body upload,
  before forwarding, and keeps an independent stream fence.
- **Resolved: completion starvation.** Bounded spool batches select completed
  receipts before applying their limit, so long-running admissions cannot hide
  finished receipts.
- **Resolved: request guardian restart.** A dynamic request guardian inherited a
  permanent restart policy. Normal completion restarted it and eventually
  stopped the service. Guardians are now temporary, and an independent timer
  targets the request owner even if the guardian dies. Regression tests cover
  both normal completion and guardian kill.
- **Resolved: public/private coupling.** Private Audi connectors no longer require
  enabling public Audi ingress or its network exception.
- **Open, high: native acceptance.** Real two-host Firecracker relocation, source
  fencing, all-profile isolation and the full provider path still require the
  acceptance suite. Kernel namespace tests cannot substitute for this evidence.
- **Open, high: capacity.** The 1,000-stream/host, fifteen-minute target has not been
  measured. Per-stream local binding polling and durable admission throughput need
  measurement under that workload before a capacity claim.
- **Operator inputs:** production root creation, issuer placement, credential
  enrollment and provider API keys require deployment-specific provisioning.
  Test roots and synthetic keys are never production defaults.

## Executed checks

The [implementation ledger](../../services/ziggy.md) records executed tests and remaining
work. Structural contract/ADR checks establish syntax and coverage only. Review
of the actual authority, credential, streaming, persistence and monitoring paths
provides a separate semantic assessment; it does not establish native capacity.

## Mandatory Lilly deployment and initial provisioning

The opt-in Ziggy module contradicted ADR-0063. Corrected it to enable automatically
with Lilly, inherit host/control/CA settings, and reject ordinary or forced false
overrides. Tests cover both refusals and the no-Lilly case. The production overalls
configuration now declares separate Ziggy, Audi frontend and issuer custody; the
public root is an explicit input to production guest packages. Generic exported
and test guest packages retain their explicit trust inputs.

Generated real five-year root/intermediate and enrolled internal service authority.
SOPS inventory validation and host-key decryption passed. Provider keys are
user-requested placeholders; no provider readiness or production activation is
claimed. The user explicitly authorized activation with placeholders: the
updater cannot declare health, and private readiness blocks new guest starts. Existing guest disks
are not rewritten by the image change. Root recovery decryption remains untested.

Production configuration evaluation exposed an issuer socket access bug: Marshall
uses per-instance dynamic users, not a shared `marshall` account. Corrected the
issuer module to attach its socket group to each Marshall systemd service; the
issuer's private credential directory remains inaccessible. Regression evaluation
covers the dynamic-user and group configuration.

Initial overalls activation exposed the gap between Marshall's systemd startup
and HTTPS readiness: first certificate acquisition failed, then succeeded once
Marshall was serving. The certificate unit now retries acquisition within a
bounded startup window. Real Audi private DNS/TLS readiness and the host leaf
SAN/expiry were verified after activation; Ziggy reports zero provider models
with placeholders, as expected.

Live monitoring exposed another socket permission boundary: the collector's
restricted root capabilities cannot bypass Unix socket write permission. Add the
existing `ziggy-proxy` supplementary group to the collector when Ziggy is enabled,
without expanding its capability set. Configuration regression checks cover this.
