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

### galileo.authorized_proxy.I3 — Prefix stripping handles null and wildcard paths
- **scope:** `Galileo.Strip`
- **must:** absent prefixes and wildcard paths MUST pass through unchanged while partial segment matches remain untouched.
- **kind:** functional
- **status:** active

### galileo.authorized_proxy.I2 — Prefix stripping is segment aligned
- **scope:** the component behavior exercised by the tagged contract test
- **must:** path prefix removal MUST preserve unrelated paths and never match partial segments.
- **kind:** security
- **status:** active

### galileo.authorized_proxy.I4 — SLO actor records terminal outcomes
- **scope:** `Galileo.SLO`
- **must:** The SLO actor MUST accept valid outcome observations and expose cumulative success/failure counts and duration totals; invalid observations MUST be rejected at the API boundary.
- **kind:** functional
- **status:** active
