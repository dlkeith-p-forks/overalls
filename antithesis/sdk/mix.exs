defmodule OverallsAntithesisSDK.MixProject do
  use Mix.Project

  def project do
    [
      app: :overalls_antithesis_sdk,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [{:jason, "~> 1.4"}, {:covenant, "~> 0.2.0", only: [:dev, :test], runtime: false}],
      aliases: [
        precommit: [
          "compile --warnings-as-errors",
          "format --check-formatted",
          "test --warnings-as-errors",
          "covenant.check --no-run"
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {OverallsAntithesis.SDK.Application, []}]
  end
end
