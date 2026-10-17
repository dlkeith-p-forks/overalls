defmodule Lilly.Network.ProxyRouting do
  @moduledoc "Owned namespace policy route for Brady's transparent socket delivery."
  alias Lilly.Host.Command
  alias Lilly.Network.Policy
  @table 1111

  # @cc [owner:ghuntley,label:security] brady-route-owned-namespace-only
  # The caller MUST establish the host's durable network claim first. Installation
  # MUST reject conflicting rule/table contents and preserve unrelated policy
  # routes. Disabled configurations MUST NOT inspect or mutate unrelated tables;
  # a previously installed route remains inert until owned namespace cleanup.
  @spec setup(Lilly.Network.Config.t()) :: :ok | {:error, :proxy_routing_failed}
  def setup(%Lilly.Network.Config{brady: nil}), do: :ok

  def setup(config) do
    with {:ok, rules} <- json(config, ["-j", "rule", "show"]),
         {:ok, routes} <- json(config, ["-j", "route", "show", "table", "all"]),
         owned_rules = Enum.filter(rules, &(&1["priority"] == @table)),
         owned_routes = Enum.filter(routes, &(&1["table"] in [@table, "1111"])),
         true <- length(owned_rules) <= 1 and Enum.all?(owned_rules, &rule?/1),
         true <- length(owned_routes) <= 1 and Enum.all?(owned_routes, &route?/1),
         :ok <-
           run(config, ["route", "replace", "local", "0.0.0.0/0", "dev", "lo", "table", "1111"]),
         :ok <- ensure_rule(config, owned_rules) do
      :ok
    else
      _ -> {:error, :proxy_routing_failed}
    end
  end

  defp rule?(rule) do
    rule["table"] in [@table, "1111"] and rule["src"] in [nil, "all"] and
      rule["fwmark"] in [Policy.brady_mark(), "0x42524144"] and
      rule["fwmask"] in [nil, "0xffffffff", 4_294_967_295] and
      Map.keys(rule) -- ~w(priority src fwmark fwmask table flags protocol) == []
  end

  defp route?(route),
    do:
      route["type"] == "local" and route["dst"] in ["default", "0.0.0.0/0"] and
        route["dev"] == "lo" and
        Map.keys(route) -- ~w(type dst dev table protocol scope flags prefsrc) == []

  defp ensure_rule(_, [_]), do: :ok

  defp ensure_rule(config, []),
    do:
      run(config, [
        "rule",
        "add",
        "priority",
        "1111",
        "fwmark",
        "0x42524144/0xffffffff",
        "lookup",
        "1111"
      ])

  defp json(config, args) do
    with {:ok, body} <- Command.in_namespace(config.namespace, :ip, args), do: JSON.decode(body)
  end

  defp run(config, args) do
    case Command.in_namespace(config.namespace, :ip, args) do
      {:ok, _} -> :ok
      _ -> {:error, :proxy_routing_failed}
    end
  end
end
