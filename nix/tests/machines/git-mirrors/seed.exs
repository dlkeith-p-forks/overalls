defmodule GitMirrorsFixture do
  # @cc [owner:ghuntley,label:security;verification] mirror-fixture-login-custody
  # Disposable login tokens MUST stay in private VM files. Browser WebAuthn
  # ceremonies MUST establish elevation; ordinary reader authority is not admin.
  @spec main() :: :ok
  def main do
    {:ok, _} = Application.ensure_all_started(:marshall)

    [bootstrap] =
      Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")

    Marshall.Compute.Ledger.update!(bootstrap, :complete, %{})
    strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)

    for {name, administrator} <- [{"reader", false}, {"admin", true}] do
      user =
        Ash.Seed.seed!(Marshall.Accounts.User, %{
          email: "#{name}@example.test",
          administrator: administrator
        })

      {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)
      path = "/run/overalls-test/git-#{name}"
      File.write!(path, token)
      File.chmod!(path, 0o600)
    end

    :ok
  end
end

GitMirrorsFixture.main()
