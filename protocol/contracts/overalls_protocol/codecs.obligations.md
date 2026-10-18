---
modules: [OverallsProtocol, OverallsProtocol.AddressPool, OverallsProtocol.AppRoute, OverallsProtocol.Cadence, OverallsProtocol.Capacity, OverallsProtocol.CloneControl, OverallsProtocol.Control.Client, OverallsProtocol.Control.Close, OverallsProtocol.Control.Envelope, OverallsProtocol.DiskLayout, OverallsProtocol.DiskTransfer, OverallsProtocol.EditorAssets, OverallsProtocol.EditorConnect, OverallsProtocol.EditorLogin, OverallsProtocol.EditorName, OverallsProtocol.EditorRelease, OverallsProtocol.EditorStream, OverallsProtocol.EgressAttribution, OverallsProtocol.Execution, OverallsProtocol.FleetCertificate, OverallsProtocol.GuestAgents, OverallsProtocol.ImageManifest, OverallsProtocol.InceptionControl, OverallsProtocol.InceptionExchange, OverallsProtocol.InceptionName, OverallsProtocol.InceptionObservation, OverallsProtocol.InceptionParent, OverallsProtocol.InceptionPublic, OverallsProtocol.Inference, OverallsProtocol.IngressCatalog, OverallsProtocol.IngressConnect, OverallsProtocol.IngressName, OverallsProtocol.IngressRoute, OverallsProtocol.Integration, OverallsProtocol.Machine, OverallsProtocol.MachineName, OverallsProtocol.NestedStream, OverallsProtocol.PrivateServices, OverallsProtocol.ProfilePolicy, OverallsProtocol.ProxyHeader, OverallsProtocol.Readiness, OverallsProtocol.Relocation, OverallsProtocol.RelocationCleanup, OverallsProtocol.RelocationDestinationCleanup, OverallsProtocol.RelocationDestinationRevocation, OverallsProtocol.RelocationImport, OverallsProtocol.RelocationKeyRetirement, OverallsProtocol.RelocationKeys, OverallsProtocol.RelocationProbe, OverallsProtocol.RelocationReadiness, OverallsProtocol.RelocationReceive, OverallsProtocol.RelocationRevocation, OverallsProtocol.RelocationSnapshotCleanup, OverallsProtocol.RelocationSource, OverallsProtocol.Resize, OverallsProtocol.SSHCommand, OverallsProtocol.SSHHostCertificate, OverallsProtocol.SSHKey, OverallsProtocol.SSHManagement, OverallsProtocol.SSHOnboarding, OverallsProtocol.SSHTrust, OverallsProtocol.Storage, OverallsProtocol.Terminal, OverallsProtocol.TerminalWindow, OverallsProtocol.TransferSSH, OverallsProtocol.VMShape, OverallsProtocol.View, OverallsProtocol.WebLogin, OverallsProtocol.WebSocket.Connection, OverallsProtocol.WebSocket.Frame, OverallsProtocol.WebSocket.Handshake, OverallsProtocol.WebStream, OverallsProtocol.WorkloadBundle, OverallsProtocol.WorkspaceSource]
---

# Codecs obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### overalls_protocol.codecs.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### overalls_protocol.codecs.I2 — Decoder rejects malformed and oversized bodies
- **scope:** `OverallsProtocol.decode/1`
- **must:** Only bounded JSON objects are accepted; malformed, non-object, and oversized bodies are rejected.
- **kind:** security
- **status:** active

### overalls_protocol.codecs.I3 — Unknown capacity remains explicit
- **scope:** `OverallsProtocol.report/1`, `uuid?/1`
- **must:** Nil reports remain unknown and UUID validation is strict.
- **kind:** functional
- **status:** active

### overalls_protocol.codecs.I4 — Capacity observations reject contradictory pools
- **scope:** `OverallsProtocol.report/1`
- **must:** Reports reject pools whose free capacity exceeds total, whose allocation credit exceeds used bytes, or whose identities are duplicated.
- **kind:** security
- **status:** active

### overalls_protocol.codecs.I5 — Capacity observations are bounded and explicit
- **scope:** `OverallsProtocol.Capacity.valid?/1`, `proof?/1`
- **must:** Nil remains the only unknown value; known observations require bounded non-negative headroom, finite coverage, and complete epoch/generation/outcome proofs, while malformed or oversized proofs are rejected.
- **kind:** security
- **status:** active

### overalls_protocol.codecs.I6 — Address profiles cannot escape reserved ranges
- **scope:** `OverallsProtocol.AddressPool.address/2`, `addresses/2`
- **must:** Only supported profiles and allocatable slots produce addresses; network and broadcast slots are rejected, and inception receives its paired address without changing ordinary profile allocation.
- **kind:** security
- **status:** active

### overalls_protocol.codecs.I7 — Application routes are a closed, secret-free table
- **scope:** `OverallsProtocol.AppRoute.parse/1`, `format/1`
- **must:** Only the documented `overalls://HOST/PATH` routes parse; userinfo, fragments, unknown paths or query keys, non-canonical identifiers and oversized input are refused without raising, and formatted routes parse back unchanged.
- **kind:** security
- **status:** active
