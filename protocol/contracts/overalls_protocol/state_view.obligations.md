---
modules: [OverallsProtocol.Cadence, OverallsProtocol.NestedStream, OverallsProtocol.View]
---

# State View obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### overalls_protocol.state_view.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### overalls_protocol.state_view.I2 — Cadence coalesces in-flight work
- **scope:** `OverallsProtocol.Cadence.step/2`
- **must:** A run starts from idle, ticks during a run do not start another run, requests coalesce into one follow-up, and completion of an idle cadence is rejected.
- **kind:** functional
- **status:** active

### overalls_protocol.state_view.I3 — View enforces single-writer ownership and versions
- **scope:** `OverallsProtocol.View`
- **must:** Only the claimant may publish, versions increase, and released rows disappear.
- **kind:** security
- **status:** active

### overalls_protocol.state_view.I4 — View index and notifications track removal
- **scope:** `OverallsProtocol.View.subscribe/2`, `lookup/2`, `delete/2`
- **must:** Published terms are discoverable, deletion removes indexed rows, and subscribers receive a change notification without row payloads.
- **kind:** functional
- **status:** active
