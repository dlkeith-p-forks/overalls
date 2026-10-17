---
modules: [OverallsAntithesis.SDK, OverallsAntithesis.SDK.Application, OverallsAntithesis.SDK.Details, OverallsAntithesis.SDK.Property, OverallsAntithesis.SDK.Writer]
---

# Sdk obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### overalls_antithesis_sdk.sdk.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active
