Code.require_file("../../scripts/test/hegel_fixtures.exs", __DIR__)

ExUnit.start(exclude: [:skip], formatters: [ExUnit.CLIFormatter, Covenant.Formatter])
