---
modules: [Brady.Connection, Brady.HTTP.Head, Brady.HTTP.Stream, Brady.Log, Brady.Proxy, Brady.TLS, Brady.TLS.Certificates, Brady.TLS.Hello, Brady.Tunnel, Brady.Upstream]
---

# Proxy obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### brady.proxy.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### brady.proxy.I2 — HTTP framing rejects ambiguous requests
- **scope:** `Brady.HTTP.Head.parse/2`
- **must:** Requests MUST require exactly one Host header and reject conflicting or duplicate body framing; valid bounded requests preserve the remaining bytes.
- **kind:** security
- **status:** active
