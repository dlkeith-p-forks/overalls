defmodule MFALoginFixture do
  # @cc [owner:ghuntley,label:security;verification] mfa-login-fixture-custody
  # Login tokens MUST remain in private disposable VM files. The ordinary reader
  # MUST NOT be the bootstrap administrator; passkeys and verification receipts
  # MUST be created by browser ceremonies, never seeded authority.
  @spec main() :: :ok
  def main do
    {:ok, _} = Application.ensure_all_started(:marshall)

    [bootstrap] =
      Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")

    Marshall.Compute.Ledger.update!(bootstrap, :complete, %{})
    strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)

    for {name, administrator, logins} <- [
          {"reader", false, ["initial", "subsequent", "expiry"]},
          {"admin", true, ["initial"]},
          {"plain", false, ["initial"]}
        ] do
      user =
        Ash.Seed.seed!(Marshall.Accounts.User, %{
          email: "#{name}@example.test",
          administrator: administrator
        })

      for login <- logins do
        {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)
        path = "/run/overalls-test/mfa-#{name}-#{login}"
        File.write!(path, token)
        File.chmod!(path, 0o600)
      end
    end

    :ok
  end
end

MFALoginFixture.main()
