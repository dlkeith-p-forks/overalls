---
modules: [Overalls.RequestAccounting.Aggregate]
---

# Aggregate obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### overalls_request_accounting.aggregate.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### overalls_request_accounting.aggregate.I2 — Outcomes and exclusions are counted consistently
- **scope:** `Overalls.RequestAccounting.Aggregate.record/3`
- **must:** Successes and failures increment their counters; excluded outcomes leave the aggregate unchanged.
- **kind:** functional
- **status:** active

### overalls_request_accounting.aggregate.I3 — Snapshots reject tampering
- **scope:** `snapshot/1`, `validate_snapshot/1`
- **must:** Produced snapshots validate, while inconsistent counts are rejected.
- **kind:** security
- **status:** active
