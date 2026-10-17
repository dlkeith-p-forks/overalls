---
modules: [Marshall.Access, Marshall.Access.AdminActions, Marshall.Access.Authorization, Marshall.Access.Change, Marshall.Access.Grant, Marshall.Access.Sharing, Marshall.Accounts, Marshall.Accounts.AccountLifecycle, Marshall.Accounts.AdminBootstrap, Marshall.Accounts.AdminEvent, Marshall.Accounts.AdminEvents, Marshall.Accounts.AdminUsers, Marshall.Accounts.Administrators, Marshall.Accounts.AuthEmail, Marshall.Accounts.AuthEmails, Marshall.Accounts.BootstrapAdministrator, Marshall.Accounts.Checks.Administrator, Marshall.Accounts.Checks.ControlRoomRead, Marshall.Accounts.Checks.InternalLookup, Marshall.Accounts.DeleteUserMachines, Marshall.Accounts.DeliverAuthEmail, Marshall.Accounts.EligibleEmail, Marshall.Accounts.EmailAddress, Marshall.Accounts.GuestAccount, Marshall.Accounts.GuestAccounts, Marshall.Accounts.GuestUsername, Marshall.Accounts.Login, Marshall.Accounts.MagicLinkSignIn, Marshall.Accounts.Passkey, Marshall.Accounts.PasskeyChallenge, Marshall.Accounts.PruneSecurity, Marshall.Accounts.RegistrationFence, Marshall.Accounts.RememberedLogin, Marshall.Accounts.Security, Marshall.Accounts.Token, Marshall.Accounts.User, Marshall.Accounts.User.Senders.SendMagicLinkEmail, Marshall.Accounts.UserDeletion, Marshall.Accounts.Verification, Marshall.Administration, Marshall.Administration.AuditEvent, Marshall.Administration.ExpireJobHistory, Marshall.Administration.JobEvent, Marshall.Administration.JobSnapshot, Marshall.Administration.Jobs, Marshall.Administration.Operations, Marshall.Authorization.AshAuthorizer, Marshall.Authorization.Cedar, Marshall.Authorization.SystemActor, Marshall.Teams, Marshall.Teams.Coordinator, Marshall.Teams.Team, Marshall.Teams.TeamMember, Marshall.Teams.Transfer, Marshall.Teams.TransferSwap]
---

# Identity Authorization obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### marshall.identity_authorization.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### marshall.identity_authorization.I2 — Compute authority is a typed internal principal
- **scope:** `Marshall.Authorization.SystemActor.compute/0` and Cedar evaluation
- **must:** The compute actor MUST carry only its explicit purpose and authorization MUST fail closed when policy state or a recognized user principal is absent.
- **kind:** security
- **status:** active
