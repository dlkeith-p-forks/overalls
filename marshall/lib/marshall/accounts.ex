defmodule Marshall.Accounts do
  use Ash.Domain, otp_app: :marshall, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Marshall.Accounts.GuestAccount
    resource Marshall.Accounts.GuestAccount.Version
    resource Marshall.Accounts.UserDeletion
    resource Marshall.Accounts.ScimMachineSuspension
    resource Marshall.Accounts.Passkey
    resource Marshall.Accounts.PasskeyChallenge
    resource Marshall.Accounts.Verification
    resource Marshall.Accounts.Token
    resource Marshall.Accounts.User
    resource Marshall.Accounts.AuthEmail
    resource Marshall.Accounts.AdminBootstrap

    resource Marshall.Accounts.AdminEvent do
      define :admin_events, action: :list_for_admin
    end
  end
end
