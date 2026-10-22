---
modules: [Marshall.Artifacts, Marshall.Artifacts.AccessChange, Marshall.Artifacts.Artifact, Marshall.Artifacts.Audit, Marshall.Artifacts.AuditEvent, Marshall.Artifacts.Authorization, Marshall.Artifacts.Blob, Marshall.Artifacts.Blobs, Marshall.Artifacts.Changes.ResumeStagedPublish, Marshall.Artifacts.Edits, Marshall.Artifacts.ExpiryJob, Marshall.Artifacts.Grant, Marshall.Artifacts.Library, Marshall.Artifacts.Limits, Marshall.Artifacts.Manifest, Marshall.Artifacts.Markdown, Marshall.Artifacts.PageHelper, Marshall.Artifacts.Paths, Marshall.Artifacts.Publisher, Marshall.Artifacts.PublishRequest, Marshall.Artifacts.PurgeJob, Marshall.Artifacts.Sharing, Marshall.Artifacts.Staging, Marshall.Artifacts.Storage, Marshall.Artifacts.StorageEntry, Marshall.Artifacts.StorageUsage, Marshall.Artifacts.SweepJob, Marshall.Artifacts.Tickets, Marshall.Artifacts.Tool, Marshall.Artifacts.UsageReconcileJob, Marshall.Artifacts.Version, Marshall.Artifacts.VersionFile, Marshall.Artifacts.ViewTicket]
---

# Artifacts obligations

## Purpose

Agent-published artifacts keep their pure publishing rules, request parsing and authorization policy observable in the BEAM test VM. Native content-origin isolation, proxy cookie stripping and guest staging are verified by the `artifact-origin` and `artifact-agent-publish` NixOS machine tests, not by these obligations.

### marshall.artifacts.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### marshall.artifacts.I2 — Edits apply all or none
- **scope:** `Marshall.Artifacts.Edits.apply/2`
- **must:** Edits MUST apply exact unique matches in order; a missing or ambiguous edit MUST return its index and leave the input unchanged.
- **kind:** functional
- **status:** active

### marshall.artifacts.I3 — Paths are normalized without traversal
- **scope:** `Marshall.Artifacts.Paths.normalize/1` and `media_type/1`
- **must:** Normalized paths MUST be relative, free of `.`/`..` segments and backslashes; unknown extensions MUST be served as attachments.
- **kind:** security
- **status:** active

### marshall.artifacts.I4 — Tool requests are closed
- **scope:** `Marshall.Artifacts.Tool.parse/1`
- **must:** Unknown operations or keys, missing `base_version` on publish, both `content` and `edits`, relative staged paths and oversize inline content MUST be refused.
- **kind:** security
- **status:** active

### marshall.artifacts.I5 — Content responses carry the lockdown header set
- **scope:** `MarshallWeb.ArtifactContentHeaders.headers/2`
- **must:** The header set MUST include a `sandbox allow-scripts` CSP without `allow-same-origin`, `connect-src 'none'`, framing limited to Marshall, COOP/COEP/CORP, nosniff, no-referrer and `private, no-store`, and MUST NOT include `set-cookie`.
- **kind:** security
- **status:** active
