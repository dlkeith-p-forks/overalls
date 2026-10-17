---
modules: [Brady.Connection, Brady.Destination, Brady.HTTP.Head, Brady.HTTP.Stream, Brady.Listener, Brady.Log, Brady.Proxy, Brady.TLS, Brady.TLS.Certificates, Brady.TLS.Hello, Brady.Transport, Brady.Tunnel, Brady.Upstream]
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

### brady.proxy.I3 — Response serialization strips hop-by-hop framing
- **scope:** `Brady.HTTP.Head.response_bytes/1`
- **must:** serialized responses MUST remove hop-by-hop and caller supplied content-length headers and emit one authoritative connection/framing policy.
- **kind:** security
- **status:** active

### brady.proxy.I4 — Destination admission and authority matching fail closed
- **scope:** `Brady.Destination` and the upstream admission boundary
- **must:** Private, special, malformed, IPv6, and invalid-port destinations MUST be rejected; an HTTP authority MUST resolve to the original admitted IPv4 address and port before upstream use.
- **kind:** security
- **status:** active

### brady.proxy.I5 — Transport and tunnel boundaries terminate safely
- **scope:** `Brady.Transport` and `Brady.Tunnel`
- **must:** Closed or failed sockets MUST return typed errors and transport close MUST be safe to call after peer closure; relay failures MUST terminate locally rather than leaking or bypassing the admitted path.
- **kind:** functional
- **status:** active
