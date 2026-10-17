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

### overalls_diagnostics.telemetry.I2 — Diagnostic payloads are redacted
- **scope:** `Overalls.Diagnostics.Privacy.filter/2`
- **must:** Filtered events use fixed messages and omit unreviewed sensitive metadata.
- **kind:** security
- **status:** active

### overalls_diagnostics.telemetry.I3 — Runtime categories are finite
- **scope:** runtime event categorization
- **must:** OTP reports map to the reviewed finite category vocabulary.
- **kind:** non-functional
- **status:** active

### overalls_diagnostics.telemetry.I4 — Catalog projections reject unknown metadata
- **scope:** `Overalls.Diagnostics.Events.Catalog.validate/3`
- **must:** Unknown events, undeclared keys, missing required fields, duplicate keys, and invalid values are rejected as a whole.
- **kind:** security
- **status:** active

### overalls_diagnostics.telemetry.I5 — Unstructured filter input is ignored
- **scope:** `Overalls.Diagnostics.Privacy.filter/2`
- **must:** Inputs outside the reviewed event map shape MUST be ignored without raising or emitting payload data.
- **kind:** security
- **status:** active

### overalls_diagnostics.telemetry.I6 — Schema predicates are strict and schema-bound
- **scope:** `Overalls.Diagnostics.Schema.uuid?/1`, `enum?/1`
- **must:** UUID validation accepts only five correctly sized hexadecimal groups, and enum validation accepts only atoms present in the reviewed trace schema; malformed terms and unknown values are rejected without conversion side effects.
- **kind:** security
- **status:** active


### overalls_diagnostics.telemetry.I7 — Metrics snapshots consume intervals exactly once
- **scope:** `Overalls.Diagnostics.Metrics.take_snapshot/0` and `reset/0`
- **must:** Accepted measurements MUST appear in the next interval snapshot, be consumed exactly once, and reset MUST clear subsequent snapshots.
- **kind:** functional
- **status:** active

### overalls_diagnostics.telemetry.I8 — Processor health remains bounded and typed
- **scope:** `Overalls.Diagnostics.Processor.health/0`
- **must:** Processor health MUST expose finite fields with non-negative integer counters and a boolean availability flag.
- **kind:** non-functional
- **status:** active
