Code.require_file("../../scripts/test/hegel_fixtures.exs", __DIR__)

ExUnit.start(formatters: [ExUnit.CLIFormatter, Covenant.Formatter])
