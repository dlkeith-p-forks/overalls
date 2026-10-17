---
modules: [OverallsProtocol.Control.Client, OverallsProtocol.Control.Close, OverallsProtocol.Control.Envelope, OverallsProtocol.WebSocket.Connection, OverallsProtocol.WebSocket.Frame, OverallsProtocol.WebSocket.Handshake]
---

# Transport obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### overalls_protocol.transport.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active
