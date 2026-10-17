---
modules: [Enrico.Application, Enrico.Config, Enrico.Events, Enrico.Git, Enrico.HTTP, Enrico.Health, Enrico.Manager, Enrico.Privacy, Enrico.RefreshSupervisor, Enrico.SLO]
---

# Mirror obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### enrico.mirror.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### enrico.mirror.I3 — Git names reject command metacharacters
- **scope:** `Enrico.Git` validators
- **must:** source, ref, and path inputs containing shell, control, or revision metacharacters MUST be rejected.
- **kind:** security
- **status:** active


### enrico.mirror.I2 — Git source and path validation rejects traversal
- **scope:** the component behavior exercised by the tagged contract test
- **must:** source, ref, and path validators MUST reject unsafe names, traversal, and absolute paths.
- **kind:** security
- **status:** active

### enrico.mirror.I4 — Refresh admission fails closed before task creation
- **scope:** `Enrico.Manager` refresh admission
- **must:** Invalid repository or attempt identifiers and invalid Git sources MUST return `{:error, :invalid_request}` without changing manager state or creating refresh work.
- **kind:** security
- **status:** active

### enrico.mirror.I5 — Configuration rejects malformed bind values safely
- **scope:** `Enrico.Config.load/1`
- **must:** Configuration documents with non-string bind values MUST return `{:error, :invalid_configuration}` without raising or creating state directories.
- **kind:** security
- **status:** active
