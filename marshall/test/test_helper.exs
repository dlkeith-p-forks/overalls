unless Code.ensure_loaded?(Overalls.HegelFixtures) do
  Code.require_file("../../scripts/test/hegel_fixtures.exs", __DIR__)
end

Code.require_file("../../scripts/test/ssh_key_callback.exs", __DIR__)

ExUnit.start(
  exclude: [:distributed, :host, :capacity],
  formatters: [ExUnit.CLIFormatter, Covenant.Formatter]
)

Ecto.Adapters.SQL.Sandbox.mode(Marshall.Repo, :manual)
