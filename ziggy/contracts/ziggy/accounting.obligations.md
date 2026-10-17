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

### ziggy.accounting.I3 — Completion wire output is bounded
- **scope:** `Ziggy.Completion`
- **must:** wire output MUST contain only the documented accounting fields and omit unrelated data.
- **kind:** functional
- **status:** active

### ziggy.accounting.I2 — Version fence probe recovery
- **scope:** `Ziggy.VersionFence`
- **must:** Refusals create a tagged probe and acceptance clears the fence; unrelated tokens cannot probe.
- **kind:** functional
- **status:** active

### ziggy.accounting.I4 — Completion validation is closed and bounded
- **scope:** `Ziggy.Completion.validate/1`
- **must:** Unknown fields, negative durations, and malformed completion records MUST be rejected before wire projection.
- **kind:** security
- **status:** active

### ziggy.accounting.I5 — Version fence backoff doubles
- **scope:** `Ziggy.VersionFence.refused/1`
- **must:** Repeated refusals MUST increase probe delay exponentially within the configured cap.
- **kind:** functional
- **status:** active
