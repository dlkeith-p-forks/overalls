---
modules: [Porsche.Listener, Porsche.SSH.Channel, Porsche.SSH.Display, Porsche.SSH.Input, Porsche.SSH.Output, Porsche.SSH.Proof]
---

# Ssh obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### porsche.ssh.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### porsche.ssh.I2 — SSH input submits CRLF once and handles interrupts
- **scope:** the component behavior exercised by the tagged contract test
- **must:** incremental input MUST submit one line for CRLF and report control-C as interrupt.
- **kind:** security
- **status:** active
