---
modules: [Lilly.Ingress.Backend, Lilly.Ingress.Guardian, Lilly.Ingress.Server, Lilly.Ingress.SocketCustody, Lilly.Network, Lilly.Network.Attribution, Lilly.Network.AttributionServer, Lilly.Network.Config, Lilly.Network.FlowLabel, Lilly.Network.FlowLookup, Lilly.Network.Guest, Lilly.Network.Ingress, Lilly.Network.Policy, Lilly.Network.ProxyRouting, Lilly.Private.Server, Lilly.Terminal.Channel, Lilly.Terminal.Guest, Lilly.Terminal.Metrics, Lilly.Terminal.Stream, Lilly.Terminal.Vsock]
---

# Network Terminal obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### lilly.network_terminal.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### lilly.network_terminal.I2 — Network text is validated and canonicalized
- **scope:** `Lilly.Network.Config.new/4` and `cidr?/1`
- **must:** Reject shell-significant interface names and non-canonical CIDRs; successful configs deduplicate and sort protected ranges.
- **kind:** security
- **status:** active

### lilly.network_terminal.I3 — Flow labels bind execution identity
- **scope:** `Lilly.Network.FlowLabel.token/2`
- **must:** Valid host, placement, epoch and generation produce a token; changing generation changes the token and malformed identities are rejected.
- **kind:** security
- **status:** active
