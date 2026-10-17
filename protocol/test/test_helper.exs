Code.require_file("support/test_generators.ex", __DIR__)
Code.require_file("support/test_properties.ex", __DIR__)
ExUnit.start(formatters: [ExUnit.CLIFormatter, Covenant.Formatter])
