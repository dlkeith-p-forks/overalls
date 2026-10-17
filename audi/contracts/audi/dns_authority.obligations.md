---
modules: [Audi.Authority.HintRenewal, Audi.Authority.Lease, Audi.Authority.Renewal, Audi.Authority.StreamGuard, Audi.DNS.Authority, Audi.DNS.Challenge, Audi.DNS.Directory, Audi.DNS.Replica, Audi.DNS.Server, Audi.DNS.Snapshot, Audi.DNS.Wire, Audi.Private.DNS, Audi.Private.Guard]
---

# Dns Authority obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### audi.dns_authority.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active
