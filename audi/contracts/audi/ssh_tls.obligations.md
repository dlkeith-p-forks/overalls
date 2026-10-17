---
modules: [Audi.SSH.Backend, Audi.SSH.Channel, Audi.SSH.ControlBackend, Audi.SSH.HostKey, Audi.SSH.KeyPublisher, Audi.SSH.Listener, Audi.SSH.Proof, Audi.SSH.Request, Audi.SSH.State, Audi.TLS.FleetCertificate, Audi.TLS.FleetMaterial, Audi.TLS.FleetWorker, Audi.TLS.Installation, Audi.TLS.Probe, Audi.TLS.Readiness, Audi.TLS.Store]
---

# Ssh Tls obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### audi.ssh_tls.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active
