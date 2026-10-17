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

### overalls_antithesis_sdk.sdk.I4 — Details reject out-of-range integers
- **scope:** `OverallsAntithesis.SDK.Details`
- **must:** negative and values beyond the signed 64-bit wire bound MUST be rejected.
- **kind:** functional
- **status:** active

### overalls_antithesis_sdk.sdk.I2 — Bounded numeric details
- **scope:** `OverallsAntithesis.SDK.Details`
- **must:** Details accept only bounded non-negative integers and wire only present fields.
- **kind:** functional
- **status:** active

### overalls_antithesis_sdk.sdk.I3 — Assertion wire shape
- **scope:** `OverallsAntithesis.SDK.Property`
- **must:** Property wire output preserves assertion kind and emits details only for hits.
- **kind:** functional
- **status:** active
