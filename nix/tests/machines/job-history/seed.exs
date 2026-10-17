defmodule JobHistoryBrowserFixture do
  # @cc [owner:ghuntley,label:security;verification] job-history-fixture-custody
  # Disposable login tokens MUST remain in private VM files and MUST NOT enter
  # output. Browser elevation MUST use the real ceremony, never seeded receipts.
  @spec main() :: :ok
  def main do
    Application.put_env(:marshall, :operator_mode, true)
    {:ok, _} = Application.ensure_all_started(:marshall)
    # This fixture represents an installed system with an existing administrator.
    # Ash.Seed alone does not consume the first-registration administrator latch.
    [bootstrap] =
      Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")

    Marshall.Compute.Ledger.update!(bootstrap, :complete, %{})
    strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)

    for {name, administrator} <- [{"reader", false}, {"admin", true}, {"operator", true}] do
      user =
        Ash.Seed.seed!(Marshall.Accounts.User, %{
          email: "#{name}@example.test",
          administrator: administrator
        })

      {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)
      path = "/run/overalls-test/job-history-#{name}"
      File.write!(path, token)
      File.chmod!(path, 0o600)
    end

    :ok
  end
end

JobHistoryBrowserFixture.main()
