# @cc [owner:ghuntley,label:verification;security] inception-inner-browser-identity
# Each inner deployment MUST create its own user and magic-link token. The token
# MUST be written only to a mode-0600 guest file, never printed or logged.
defmodule InceptionInnerBrowserFixture do
  @moduledoc false
  @spec run() :: :ok
  def run do
    instance = System.fetch_env!("INCEPTION_BROWSER_INSTANCE")
    true = instance in ["1", "2"]
    Application.put_env(:marshall, :operator_mode, true)
    {:ok, _} = Application.ensure_all_started(:marshall)
    user = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "browser-#{instance}@example.test"})
    strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)
    {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)
    path = "/root/inception-browser-token.json"
    :ok = File.write(path, JSON.encode!(%{token: token}), [:write])
    :ok = File.chmod(path, 0o600)
  end
end

InceptionInnerBrowserFixture.run()
