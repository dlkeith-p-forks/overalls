defmodule Marshall.Operations.OperatorBootPropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  @project Path.expand("../../..", __DIR__)
  @type projection :: %{
          required(String.t()) => boolean() | [String.t()]
        }

  # @cc [owner:ghuntley,label:verification;security] operator-boot-isolation-property
  # Every valid operator-mode boot MUST initialize a non-serving endpoint and
  # PubSub, disable Oban consumers, and use the exact reduced child set.
  # One hundred real BEAM subprocess boots require a bounded aggregate budget.
  @tag timeout: 180_000
  property "operator boots retain serving and queue isolation across valid environments",
    test_cases: 100 do
    server = draw("server", member_of(["false", ""]))
    {projection, output} = probe(server)

    assert projection == %{
             "children" => [
               "Elixir.Marshall.Authorization.Cedar",
               "Elixir.Marshall.Repo",
               "Elixir.Marshall.Vault",
               "Elixir.MarshallWeb.Endpoint",
               "Elixir.Oban",
               "Elixir.Phoenix.PubSub.Supervisor"
             ],
             "endpoint_present" => true,
             "endpoint_server_disabled" => true,
             "queues_empty" => true,
             "plugins_empty" => true,
             "stager_disabled" => true,
             "isolated_peer" => true
           }

    refute String.contains?(output, "SECRET")
  end

  @spec probe(String.t()) :: {projection(), String.t()}
  defp probe(server) do
    {output, status} =
      System.cmd(
        "elixir",
        ["scripts/operator_boot_probe.exs"],
        cd: @project,
        env: [{"MIX_ENV", "test"}, {"PHX_SERVER", server}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    [encoded] = for "OPERATOR_PROBE:" <> encoded <- String.split(output, "\n"), do: encoded
    assert {:ok, projection} = JSON.decode(encoded)
    {projection, output}
  end
end
