Code.require_file("../../scripts/test/hegel_fixtures.exs", __DIR__)

Ecto.Adapters.SQL.Sandbox.mode(Susan.Repo, :manual)
ExUnit.start(exclude: [:skip], formatters: [ExUnit.CLIFormatter, Covenant.Formatter])
