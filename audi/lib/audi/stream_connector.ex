defmodule Audi.StreamConnector do
  @moduledoc "Selects only the local connector or a control-authorized single fleet hop."

  # @cc [owner:ghuntley,label:security] audi-stream-connector-one-hop
  # A remote grant MUST use its validated one-hop capability. Local bindings
  # MUST retain the configured Unix connector. Neither application headers nor
  # guest bytes may select a transport endpoint or trigger a retry.
  @spec open({module(), term()}, map()) :: {:ok, :gen_tcp.socket()} | {:error, atom()}
  def open({_module, %{relay: local}}, %{relay: relay} = grant),
    do: Audi.Relay.Client.open(relay, grant, local)

  def open(_connector, %{relay: _}), do: {:error, :connector_unavailable}
  def open({module, options}, grant), do: module.open(options, grant.binding)
end
