defmodule MarshallIdentityAuthorizationContractTest do
  use Covenant.Case, component: "marshall.identity_authorization"

  @tag obligation: "marshall.identity_authorization.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Marshall.Access,
      Marshall.Access.AdminActions,
      Marshall.Access.Authorization,
      Marshall.Access.Change,
      Marshall.Access.Grant,
      Marshall.Access.Sharing,
      Marshall.Accounts,
      Marshall.Accounts.AccountLifecycle,
      Marshall.Accounts.AdminBootstrap,
      Marshall.Accounts.AdminEvent,
      Marshall.Accounts.AdminEvents,
      Marshall.Accounts.AdminUsers,
      Marshall.Accounts.Administrators,
      Marshall.Accounts.AuthEmail,
      Marshall.Accounts.AuthEmails,
      Marshall.Accounts.BootstrapAdministrator,
      Marshall.Accounts.Checks.Administrator,
      Marshall.Accounts.Checks.ControlRoomRead,
      Marshall.Accounts.Checks.InternalLookup,
      Marshall.Accounts.DeleteUserMachines,
      Marshall.Accounts.DeliverAuthEmail,
      Marshall.Accounts.EligibleEmail,
      Marshall.Accounts.EmailAddress,
      Marshall.Accounts.GuestAccount,
      Marshall.Accounts.GuestAccounts,
      Marshall.Accounts.GuestUsername,
      Marshall.Accounts.Login,
      Marshall.Accounts.MagicLinkSignIn,
      Marshall.Accounts.Passkey,
      Marshall.Accounts.PasskeyChallenge,
      Marshall.Accounts.PruneSecurity,
      Marshall.Accounts.RegistrationFence,
      Marshall.Accounts.RememberedLogin,
      Marshall.Accounts.Security,
      Marshall.Accounts.Token,
      Marshall.Accounts.User,
      Marshall.Accounts.User.Senders.SendMagicLinkEmail,
      Marshall.Accounts.UserDeletion,
      Marshall.Accounts.Verification,
      Marshall.Administration,
      Marshall.Administration.AuditEvent,
      Marshall.Administration.ExpireJobHistory,
      Marshall.Administration.JobEvent,
      Marshall.Administration.JobSnapshot,
      Marshall.Administration.Jobs,
      Marshall.Administration.Operations,
      Marshall.Authorization.AshAuthorizer,
      Marshall.Authorization.Cedar,
      Marshall.Authorization.SystemActor,
      Marshall.Teams,
      Marshall.Teams.Coordinator,
      Marshall.Teams.Team,
      Marshall.Teams.TeamMember,
      Marshall.Teams.Transfer,
      Marshall.Teams.TransferSwap
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "marshall.identity_authorization.I2"
  test "the compute actor is a typed, non-user principal" do
    actor = Marshall.Authorization.SystemActor.compute()
    assert %Marshall.Authorization.SystemActor{purpose: :compute} = actor
    refute Map.has_key?(actor, :id)

    assert Marshall.Authorization.Cedar.allowed?(
             actor,
             "read",
             Marshall.Authorization.Cedar.entity("VM", "vm-1")
           ) == false
  end

  @tag obligation: "marshall.identity_authorization.I3"
  test "account boundary validators reject unsafe identity input" do
    assert Marshall.Accounts.EmailAddress.valid?("alice@example.com")
    refute Marshall.Accounts.EmailAddress.valid?("Alice Example <alice@example.com>")
    refute Marshall.Accounts.EmailAddress.valid?("alice\r\n@example.com")
    refute Marshall.Accounts.EmailAddress.valid?(String.duplicate("a", 255) <> "@x.test")
    refute Marshall.Accounts.EmailAddress.valid?(nil)
    refute Marshall.Accounts.EmailAddress.valid?("alice @example.com")

    assert Marshall.Accounts.GuestUsername.from_uid(200_000) == {:ok, "u200000"}
    assert Marshall.Accounts.GuestUsername.from_uid(999_999) == {:ok, "u999999"}
    assert Marshall.Accounts.GuestUsername.from_uid(199_999) == :error
    assert Marshall.Accounts.GuestUsername.from_uid(1_000_000) == :error
    assert Marshall.Accounts.GuestUsername.from_uid("200000") == :error
  end

  @tag obligation: "marshall.identity_authorization.I4"
  test "security proof freshness is bounded in both directions" do
    verified = ~U[2026-01-01 00:00:00Z]
    now = ~U[2026-01-01 00:05:00Z]
    expiry = ~U[2026-01-01 00:10:00Z]

    assert Marshall.Accounts.Security.elevation_fresh?(verified, expiry, now)
    refute Marshall.Accounts.Security.elevation_fresh?(~U[2026-01-01 00:11:00Z], expiry, now)
    refute Marshall.Accounts.Security.elevation_fresh?(verified, ~U[2026-01-01 00:04:59Z], now)
    refute Marshall.Accounts.Security.elevation_fresh?(nil, expiry, now)

    assert Marshall.Accounts.Security.email_fresh?(~U[2026-01-01 00:04:00Z], now)
    refute Marshall.Accounts.Security.email_fresh?(~U[2025-12-31 23:00:00Z], now)
    refute Marshall.Accounts.Security.email_fresh?(nil, now)
  end
end
