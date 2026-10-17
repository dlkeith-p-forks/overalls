---
modules: [Ziggy.Catalog, Ziggy.Completion, Ziggy.Pricing, Ziggy.Reporter, Ziggy.SLO, Ziggy.SLOCheckpoint, Ziggy.Spool, Ziggy.Usage, Ziggy.VersionFence]
---

# Accounting obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### ziggy.accounting.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### ziggy.accounting.I2 — Version fence probe recovery
- **scope:** `Ziggy.VersionFence`
- **must:** Refusals create a tagged probe and acceptance clears the fence; unrelated tokens cannot probe.
- **kind:** functional
- **status:** active
