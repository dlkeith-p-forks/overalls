defmodule Peach.MixProject do
  use Mix.Project
  def project, do: [app: :peach, version: "0.1.0", elixir: "== 1.20.4", deps: deps()]

  def application,
    do: [extra_applications: [:logger, :crypto, :ssl], mod: {Peach.Application, []}]

  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:overalls_protocol, path: "../protocol"},
      {:overalls_diagnostics, path: "../elixir/diagnostics"}
    ]
  end
end
