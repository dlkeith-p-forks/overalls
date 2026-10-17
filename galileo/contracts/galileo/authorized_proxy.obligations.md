---
modules: [Galileo.Application, Galileo.Config, Galileo.Control, Galileo.Counter, Galileo.Credential, Galileo.Events, Galileo.HTTP, Galileo.Privacy, Galileo.SLO, Galileo.Strip, Galileo.Upstream]
---

# Authorized Proxy obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### galileo.authorized_proxy.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### galileo.authorized_proxy.I2 — Prefix stripping is segment aligned
- **scope:** the component behavior exercised by the tagged contract test
- **must:** path prefix removal MUST preserve unrelated paths and never match partial segments.
- **kind:** security
- **status:** active
