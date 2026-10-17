---
modules: [Audi.Connector, Audi.HTTP.Authority, Audi.HTTP.Browser, Audi.HTTP.Editor, Audi.HTTP.EditorAssets, Audi.HTTP.EditorAssetsProbe, Audi.HTTP.EditorAssetsPublisher, Audi.HTTP.EditorBrowser, Audi.HTTP.Front, Audi.HTTP.Headers, Audi.HTTP.Listener, Audi.HTTP.Proxy, Audi.HTTP.TLSTransport, Audi.HTTP.WebSocket, Audi.HTTP.WebSocketFrame, Audi.HTTP.WebSocketUpgrade, Audi.Inception.Authority, Audi.Inception.ClientHello, Audi.Inception.Front, Audi.Inception.Peer]
---

# Http Gateway obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### audi.http_gateway.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### audi.http_gateway.I2 — Guest response cookies are host-only
- **scope:** the component behavior exercised by the tagged contract test
- **must:** `Audi.HTTP.Headers.response/1` MUST remove Domain attributes and reserved platform cookies.
- **kind:** security
- **status:** active

### audi.http_gateway.I3 — WebSocket frames preserve payloads and bound controls
- **scope:** `Audi.HTTP.WebSocketFrame`
- **must:** encoded text frames MUST decode losslessly; control frames larger than 125 bytes MUST be rejected.
- **kind:** security
- **status:** active
