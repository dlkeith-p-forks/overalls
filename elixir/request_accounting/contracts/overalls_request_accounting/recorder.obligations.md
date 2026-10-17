---
modules: [Overalls.RequestAccounting.Config, Overalls.RequestAccounting.Producer, Overalls.RequestAccounting.Producer.Server, Overalls.RequestAccounting.QualityMarker, Overalls.RequestAccounting.RecorderRPC]
---

# Recorder obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### overalls_request_accounting.recorder.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### overalls_request_accounting.recorder.I2 — Quality markers are private and round-trip
- **scope:** `QualityMarker.write/2`, `read/1`
- **must:** A mode-0700 directory accepts valid quality states and round-trips them; invalid states and non-private directories are refused.
- **kind:** security
- **status:** active
