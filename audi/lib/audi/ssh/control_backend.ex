defmodule Audi.SSH.ControlBackend do
  @moduledoc "Real Marshall session authority with an explicitly supplied local connector."
  @behaviour Audi.SSH.Backend
  alias Audi.Control.Client

  @impl true
  def key_status(%{client: client}, key), do: Client.ssh_key_status(client, key.public_key)

  # @cc [owner:ghuntley,label:security] audi-control-backend-local-connector
  # Authority MUST use the configured verified Marshall client. Only a locally
  # configured connector implementation may open a socket; peer commands cannot
  # choose its module, configuration, address or port. Missing connector denies.
  @impl true
  def authorize(%{client: client}, key, {:nested, label, service})
      when service in [:porsche_ssh, :audi_ssh] do
    with {:ok, grant} <- Client.open_nested(client, label, service, key.public_key) do
      {:ok,
       grant
       |> Map.put(:ticket, {:nested, grant.ticket, grant.host_key})
       |> Map.put(:ttl, grant.expires_at - grant.requested_at)}
    end
  end

  def authorize(%{client: client}, key, label) do
    with {:ok, grant} <- Client.open_ssh(client, key.public_key, label) do
      if Map.has_key?(grant, :relay),
        do: {:ok, Map.put(grant, :ticket, {:relay, grant.ticket, grant.relay})},
        else: {:ok, grant}
    end
  end

  @impl true
  def renew(%{client: client}, {:nested, ticket, host_key}, binding) do
    with {:ok, grant} <-
           Client.renew_nested(client, ticket, %{binding: binding, host_key: host_key}) do
      {:ok, Map.put(grant, :ttl, grant.expires_at - grant.requested_at)}
    end
  end

  def renew(%{client: client}, {:relay, ticket, _relay}, binding),
    do: Client.renew_ssh(client, ticket, binding)

  def renew(%{client: client}, ticket, binding), do: Client.renew_ssh(client, ticket, binding)

  @impl true
  def connect(%{connector: connector}, {:relay, ticket, relay}, binding),
    do: Audi.StreamConnector.open(connector, %{ticket: ticket, binding: binding, relay: relay})

  def connect(%{connector: {module, options}}, _ticket, binding),
    do: module.open(options, binding)

  def connect(_, _, _), do: {:error, :connector_unavailable}
end
