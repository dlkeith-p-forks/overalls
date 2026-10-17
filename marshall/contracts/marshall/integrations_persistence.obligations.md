---
modules: [Marshall.Editor, Marshall.Editor.Audit, Marshall.Editor.Authority, Marshall.Editor.Credential, Marshall.Editor.Lease, Marshall.Editor.Login, Marshall.Editor.Retention, Marshall.Editor.Token, Marshall.Enrico, Marshall.Enrico.AuditEvent, Marshall.Enrico.Catalog, Marshall.Enrico.Client, Marshall.Enrico.EnricoSource, Marshall.Enrico.Repository, Marshall.Enrico.Worker, Marshall.Galileo, Marshall.Galileo.AdminActions, Marshall.Galileo.Attachment, Marshall.Galileo.Authorizations, Marshall.Galileo.Configurations, Marshall.Galileo.Credential, Marshall.Galileo.Credentials, Marshall.Galileo.Integration, Marshall.Galileo.IntegrationHeader, Marshall.Galileo.IssuedCredential, Marshall.Galileo.Ownership, Marshall.Galileo.PeerToken, Marshall.Galileo.PeerTokens, Marshall.Inference, Marshall.Inference.ControlRequests, Marshall.Inference.Credential, Marshall.Inference.Credentials, Marshall.Inference.Daily, Marshall.Inference.IssuedCredential, Marshall.Inference.Request, Marshall.Inference.Requests, Marshall.Inference.Retention, Marshall.Inference.Totals, Marshall.Inference.Views, Marshall.Ingress, Marshall.Ingress.ACME.AccountKey, Marshall.Ingress.ACME.Issuer, Marshall.Ingress.ACME.JWS, Marshall.Ingress.ACME.Material, Marshall.Ingress.ACME.Propagation, Marshall.Ingress.ACME.Request, Marshall.Ingress.ACME.Resources, Marshall.Ingress.ACME.Transport, Marshall.Ingress.Catalog, Marshall.Ingress.CertificateAuthority, Marshall.Ingress.ControlRequests, Marshall.Ingress.EditorAssets, Marshall.Ingress.EditorAssetsReceipt, Marshall.Ingress.Endpoint, Marshall.Ingress.Endpoints, Marshall.Ingress.EnsureFleetCertificate, Marshall.Ingress.Environment, Marshall.Ingress.EnvironmentAuthority, Marshall.Ingress.EnvironmentDiscovery, Marshall.Ingress.EnvironmentPublication, Marshall.Ingress.EnvironmentPublications, Marshall.Ingress.EnvironmentStream, Marshall.Ingress.EnvironmentStreamRetention, Marshall.Ingress.EnvironmentStreams, Marshall.Ingress.Environments, Marshall.Ingress.Error, Marshall.Ingress.Execution, Marshall.Ingress.FleetACMEConfig, Marshall.Ingress.FleetCertificate, Marshall.Ingress.FleetCertificateAccount, Marshall.Ingress.FleetCertificateAudit, Marshall.Ingress.FleetCertificateDelivery, Marshall.Ingress.FleetCertificateInstallation, Marshall.Ingress.FleetCertificateProgress, Marshall.Ingress.Publication, Marshall.Ingress.Publications, Marshall.Ingress.Retention, Marshall.Ingress.RotateFleetCertificate, Marshall.Ingress.Route, Marshall.Ingress.Routes, Marshall.Ingress.Service, Marshall.Ingress.Services, Marshall.Ingress.Session, Marshall.Ingress.Sessions, Marshall.Ingress.Token, Marshall.Ingress.WebCredential, Marshall.Ingress.WebLogin, Marshall.Ingress.WebLogins, Marshall.Ingress.WebRetention, Marshall.Ingress.WebStream, Marshall.Ingress.WebStreams, Marshall.Mailer, Marshall.Mailer.Config, Marshall.Mailer.LogFilter, Marshall.Operations.Audi, Marshall.Operations.CLI, Marshall.Operations.Galileo, Marshall.Operations.Health, Marshall.Operations.Inference, Marshall.Operations.Migrate, Marshall.Operations.Privacy, Marshall.Operations.PrivateFiles, Marshall.Operations.RuntimeConfig, Marshall.Operations.SSHGateway]
---

# Integrations Persistence obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### marshall.integrations_persistence.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### marshall.integrations_persistence.I2 — Registered Git source names are bounded
- **scope:** `Marshall.Enrico.EnricoSource.valid?/2`
- **must:** Repository owner and name validation MUST reject traversal, `.git` suffixes, and malformed names before persistence or fetch.
- **kind:** security
- **status:** active
