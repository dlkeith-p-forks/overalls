---
modules: [Porsche.Client, Porsche.Connection, Porsche.Control.Link, Porsche.Observability, Porsche.Runner, Porsche.StatusServer]
---

# Control Transport obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### porsche.control_transport.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### porsche.control_transport.I2 — Control client configuration is constrained
- **scope:** `Porsche.Client.new/3`
- **must:** Only HTTPS host origins, valid tokens, and known options are accepted; IPv6 literals and HTTP origins are rejected.
- **kind:** security
- **status:** active
