---
modules: [Marshall.SSH, Marshall.SSH.AdminActions, Marshall.SSH.Approval, Marshall.SSH.Authority, Marshall.SSH.Commands, Marshall.SSH.ControlRequests, Marshall.SSH.Error, Marshall.SSH.Gateway, Marshall.SSH.GuestAccess, Marshall.SSH.GuestLogin, Marshall.SSH.HostCertificate, Marshall.SSH.HostCertificateRetention, Marshall.SSH.HostCertificates, Marshall.SSH.Key, Marshall.SSH.KeyActions, Marshall.SSH.KeyRegistry, Marshall.SSH.Request, Marshall.SSH.Retention, Marshall.SSH.Session, Marshall.SSH.Token, Marshall.Terminal, Marshall.Terminal.Authority, Marshall.Terminal.Creation, Marshall.Terminal.Directory, Marshall.Terminal.Event, Marshall.Terminal.Grant, Marshall.Terminal.HostStream, Marshall.Terminal.Location, Marshall.Terminal.Metrics, Marshall.Terminal.Opening, Marshall.Terminal.PeerBudget, Marshall.Terminal.PeerSocket, Marshall.Terminal.Reconciler, Marshall.Terminal.Relay, Marshall.Terminal.Remote, Marshall.Terminal.Session, Marshall.Terminal.Sharing, Marshall.Terminal.Termination, Marshall.Terminal.Ticket, Marshall.Terminal.TicketRetention, Marshall.Terminal.Tickets, Marshall.Terminal.Viewer, Marshall.Terminal.ViewerAuthority]
---

# Ssh Terminal obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### marshall.ssh_terminal.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active
