---
modules: [Brady.Attribution, Brady.Cache, Brady.Cache.Archive, Brady.Cache.Budget, Brady.Cache.Policy, Brady.Cache.Pressure, Brady.Cache.Range, Brady.Cache.Recovery, Brady.Cache.Runtime, Brady.Cache.Store, Brady.Metrics]
---

# Cache obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### brady.cache.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### brady.cache.I3 — Range validators fail closed
- **scope:** `Brady.Cache.Range`
- **must:** unmatched validators MUST route upstream and ranges outside the representation MUST be unsatisfiable.
- **kind:** security
- **status:** active

### brady.cache.I2 — Range selection never serves invalid ranges
- **scope:** the component behavior exercised by the tagged contract test
- **must:** malformed or multi-range requests MUST route upstream; valid bounded ranges return partial selections.
- **kind:** security
- **status:** active
