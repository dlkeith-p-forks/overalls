defmodule OverallsProtocol.MixProject do
  use Mix.Project

  def project do
    [
      app: :overalls_protocol,
      version: "0.1.0",
      elixir: "== 1.20.4",
      test_ignore_filters: ["test/support/control_close_peer.ex"],
      deps: [
        {:covenant, "~> 0.2.0", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
        {:hegel_ex,
         git: "https://github.com/ghuntley/hegel-erlang.git",
         ref: "dbe9e9a",
         subdir: "packages/hegel_ex",
         only: [:dev, :test],
         runtime: false}
      ],
      aliases: [
        "toolchain.check": [fn _ -> Code.eval_file("../scripts/check_toolchain.exs", __DIR__) end],
        "architecture.check": [&check_adrs/1],
        "contracts.check": [fn _ -> Code.eval_file("../scripts/check_contracts.exs", __DIR__) end],
        precommit: [
          "toolchain.check",
          "architecture.check",
          "contracts.check",
          "compile --warnings-as-errors",
          "deps.unlock --unused",
          "format --check-formatted",
          "test --warnings-as-errors",
          "covenant.check --no-run",
          "dialyzer"
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto, :ssl, :public_key]]
  def cli, do: [preferred_envs: [precommit: :test]]

  defp check_adrs(_) do
    Code.require_file("../scripts/adr_validator.ex", __DIR__)

    case Overalls.ADRValidator.check(Path.expand("..", __DIR__)) do
      {:ok, count} -> Mix.shell().info("ADR check passed (#{count} decisions).")
      {:error, errors} -> Mix.raise(Enum.join(errors, "\n"))
    end
  end
end
