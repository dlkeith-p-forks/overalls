---
modules: [Peach.Application, Peach.Config, Peach.Control, Peach.Control.Link, Peach.Credential, Peach.Events, Peach.HTTP, Peach.Privacy]
---

# Reflection obligations

## Purpose

Peach serves the secret-free `reflection.internal` projection for the running guest named by Audi's binding, after Marshall authorizes that exact execution. Native socket access, private TLS and deployment remain governed by the repository's `CONTRACTS`, ADR and NixOS evidence.

### peach.reflection.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM.
- **kind:** non-functional
- **status:** active

### peach.reflection.I2 — Unknown paths never reach Marshall
- **scope:** `Peach.HTTP`
- **must:** A request for a path outside `/`, `/guest` and `/integrations`, a non-GET method or a query MUST be refused without a control request.
- **kind:** security
- **status:** active

### peach.reflection.I3 — Bindings for another host are refused
- **scope:** `Peach.HTTP`
- **must:** A missing, duplicated, malformed or foreign-host binding MUST answer 403 without a control request.
- **kind:** security
- **status:** active

### peach.reflection.I4 — Failed control admission returns no projection
- **scope:** `Peach.HTTP`, `Peach.Control`
- **must:** A Marshall refusal, outage or protocol-invalid snapshot MUST NOT return a projection or a retained earlier snapshot.
- **kind:** security
- **status:** active
