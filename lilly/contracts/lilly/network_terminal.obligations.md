---
modules: [Lilly.Ingress.Backend, Lilly.Ingress.Guardian, Lilly.Ingress.Server, Lilly.Ingress.SocketCustody, Lilly.Network, Lilly.Network.Attribution, Lilly.Network.AttributionServer, Lilly.Network.Config, Lilly.Network.FlowLabel, Lilly.Network.FlowLookup, Lilly.Network.Guest, Lilly.Network.Ingress, Lilly.Network.Policy, Lilly.Network.ProxyRouting, Lilly.Terminal.Channel, Lilly.Terminal.Guest, Lilly.Terminal.Metrics, Lilly.Terminal.Stream, Lilly.Terminal.Vsock]
---

# Network Terminal obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### lilly.network_terminal.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active
