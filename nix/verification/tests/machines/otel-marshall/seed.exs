defmodule OTelSloReaderSeed do
  @moduledoc false

  # @cc [owner:ghuntley,label:security;verification] slo-fixture-token-custody
  # The disposable reader token MUST stay in a private file and never enter
  # test output. The reader MUST be ordinary, with bootstrap already complete.
  @spec run() :: :ok
  def run do
    {:ok, _} = Application.ensure_all_started(:marshall)

    Ash.Seed.seed!(Marshall.Accounts.User, %{
      email: "slo-bootstrap@example.test",
      administrator: true
    })

    [bootstrap] =
      Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")

    Marshall.Compute.Ledger.update!(bootstrap, :complete, %{})

    user = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "slo-reader@example.test"})
    strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)
    {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)
    File.write!("/run/overalls-test/otel-slo-token", token)
    File.chmod!("/run/overalls-test/otel-slo-token", 0o600)
  end
end

OTelSloReaderSeed.run()
