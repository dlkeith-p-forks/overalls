defmodule OverallsProtocol.MixProject do
  use Mix.Project

  def project do
    [
      app: :overalls_protocol,
      version: "0.1.0",
      elixir: "== 1.20.4",
      test_ignore_filters: ["test/support/control_close_peer.ex"],
      deps: [
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
        {:stream_data, "~> 1.4", only: :test}
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
