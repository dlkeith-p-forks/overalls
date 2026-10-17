---
modules: [MarshallWeb, MarshallWeb.Admin.AccessLive, MarshallWeb.Admin.AuditLive, MarshallWeb.Admin.GitLive, MarshallWeb.Admin.JobsLive, MarshallWeb.Admin.LillyNodesLive, MarshallWeb.Admin.OperationsLive, MarshallWeb.Admin.UsersLive, MarshallWeb.Admin.WorkloadsLive, MarshallWeb.AdminElevation, MarshallWeb.AgentCLIApprovalLive, MarshallWeb.AgentCLIController, MarshallWeb.AgentThreadsLive, MarshallWeb.AudiLoginController, MarshallWeb.AuthController, MarshallWeb.AuthOverrides, MarshallWeb.AuthText, MarshallWeb.AuthenticationPrivacy, MarshallWeb.AutomaticMagicSignInLive, MarshallWeb.CloneComponents, MarshallWeb.ControlAPI, MarshallWeb.CoreComponents, MarshallWeb.DatabaseWait, MarshallWeb.DocsController, MarshallWeb.DocsHTML, MarshallWeb.EditorController, MarshallWeb.Endpoint, MarshallWeb.ErrorHTML, MarshallWeb.ErrorJSON, MarshallWeb.FleetEndpoint, MarshallWeb.Gettext, MarshallWeb.GitLive, MarshallWeb.GitRawController, MarshallWeb.HLDDLive, MarshallWeb.Health, MarshallWeb.InferenceExportController, MarshallWeb.InferenceLive, MarshallWeb.IngressAPI, MarshallWeb.IngressKnownHosts, MarshallWeb.IntegrationsLive, MarshallWeb.LaunchLive, MarshallWeb.Layouts, MarshallWeb.LiveAdminAuth, MarshallWeb.LiveSocket, MarshallWeb.LiveUserAuth, MarshallWeb.MachineDefaults, MarshallWeb.MachineWorkspace, MarshallWeb.MachinesLive, MarshallWeb.MarvinDownloadController, MarshallWeb.ObservedRouter, MarshallWeb.OverallsController, MarshallWeb.OverallsInstaller, MarshallWeb.OverviewLive, MarshallWeb.PageController, MarshallWeb.PageHTML, MarshallWeb.PendingLaunch, MarshallWeb.ProvisionerAPI, MarshallWeb.PublicIngress, MarshallWeb.RepositoryLaunchController, MarshallWeb.ResizeLive, MarshallWeb.Router, MarshallWeb.SSHAPI, MarshallWeb.SSHApprovalLive, MarshallWeb.SSHApprovalLogin, MarshallWeb.SSHKeysLive, MarshallWeb.SecurityLive, MarshallWeb.TeamsLive, MarshallWeb.Telemetry, MarshallWeb.TerminalLive, MarshallWeb.TerminalLogFilter, MarshallWeb.TerminalNames, MarshallWeb.TerminalOpening, MarshallWeb.TerminalPeerAPI, MarshallWeb.TerminalSocket, MarshallWeb.ThreadCommands, MarshallWeb.ThreadsLive, MarshallWeb.WorkspaceComponents]
---

# Web Surface obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### marshall.web_surface.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### marshall.web_surface.I2 — Health probes disclose no session data
- **scope:** `MarshallWeb.Health`
- **must:** Live health responses MUST be fixed, uncached text; HEAD responses MUST have an empty body.
- **kind:** security
- **status:** active
