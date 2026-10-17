---
modules: [Overalls.Diagnostics, Overalls.Diagnostics.Application, Overalls.Diagnostics.Configuration, Overalls.Diagnostics.Context, Overalls.Diagnostics.Custody, Overalls.Diagnostics.Events.Catalog, Overalls.Diagnostics.Exporter, Overalls.Diagnostics.Formatter, Overalls.Diagnostics.IdGenerator, Overalls.Diagnostics.Metrics, Overalls.Diagnostics.Privacy, Overalls.Diagnostics.Processor, Overalls.Diagnostics.Sampler, Overalls.Diagnostics.Schema, Overalls.Diagnostics.Tracing]
---

# Telemetry obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### overalls_diagnostics.telemetry.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active
