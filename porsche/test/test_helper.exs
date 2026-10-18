Code.require_file("../../scripts/test/hegel_fixtures.exs", __DIR__)
Code.require_file("../../scripts/test/ssh_key_callback.exs", __DIR__)
ExUnit.start(formatters: [ExUnit.CLIFormatter, Covenant.Formatter])
