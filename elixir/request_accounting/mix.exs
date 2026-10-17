defmodule Overalls.RequestAccounting.MixProject do
  use Mix.Project

  def project do
    [
      app: :overalls_request_accounting,
      version: "0.1.0",
      elixir: "== 1.20.4",
      deps: [
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
        {:stream_data, "~> 1.4", only: :test}
      ],
      aliases: [
        "toolchain.check": [
          fn _ -> Code.eval_file("../../scripts/check_toolchain.exs", __DIR__) end
        ],
        "architecture.check": [
          fn _ -> Code.eval_file("../../scripts/check_adrs.exs", __DIR__) end
        ],
        "contracts.check": [
          fn _ -> Code.eval_file("../../scripts/check_contracts.exs", __DIR__) end
        ],
        precommit: [
          "toolchain.check",
          "architecture.check",
          "contracts.check",
          "compile --warnings-as-errors",
          "format --check-formatted",
          "test --warnings-as-errors",
          "dialyzer --force-check"
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto]]
  def cli, do: [preferred_envs: [precommit: :test]]
end
