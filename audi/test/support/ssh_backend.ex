defmodule Audi.SSHBackendFixture do
  @moduledoc false
  @behaviour Audi.SSH.Backend
  @id "11111111-1111-4111-8111-111111111111"
  @type config :: %{owner: pid(), agent: pid(), port: :inet.port_number()}
  @type ticket :: :fixture_ticket | {:fixture_ticket, binary()}

  @impl true
  def key_status(config, key) do
    send(config.owner, {:key_status, key})
    Agent.get(config.agent, &Map.get(&1, :key_status, {:ok, :recognized}))
  end

  @impl true
  @spec authorize(config(), OverallsProtocol.SSHKey.t(), Audi.SSH.Request.selector()) ::
          {:ok, Audi.SSH.Backend.grant()} | {:error, :denied}
  def authorize(config, key, label) do
    send(config.owner, {:authorized, key, label})
    state = Agent.get(config.agent, & &1)

    case Map.get(state, :authorization_gate) do
      nil ->
        :ok

      fence when is_reference(fence) ->
        send(config.owner, {:authorization_waiting, fence, self()})

        receive do
          {:release_authorization, ^fence} -> :ok
        after
          5_000 -> raise "authorization fixture barrier timed out"
        end
    end

    if state.allow do
      {label, service} =
        case label do
          {:nested, label, service} -> {label, service}
          label -> {label, :ssh}
        end

      binding = %{
        vm_id: @id,
        placement_id: @id,
        host_id: state.host,
        session_id: @id,
        execution_epoch: 1,
        generation: 1,
        service: service,
        port: 22,
        label: label
      }

      if service == :ssh do
        {:ok, %{binding: binding, ticket: :fixture_ticket, ttl: state.ttl}}
      else
        {:ok,
         %{
           binding: Map.put(binding, :environment_generation, 1),
           ticket: {:fixture_ticket, Map.get(state, :host_key, key.public_key)},
           host_key: Map.get(state, :host_key, key.public_key),
           ttl: state.ttl
         }}
      end
    else
      {:error, :denied}
    end
  end

  @impl true
  @spec connect(config(), ticket(), map()) :: {:ok, :gen_tcp.socket()} | {:error, atom()}
  def connect(config, {:fixture_ticket, _}, binding),
    do: connect(config, :fixture_ticket, binding)

  def connect(config, :fixture_ticket, _) do
    send(config.owner, :connector_called)
    port = Agent.get(config.agent, &Map.get(&1, :port, config.port))
    :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)
  end

  @impl true
  def renew(config, {:fixture_ticket, key}, binding) do
    with {:ok, grant} <- renew(config, :fixture_ticket, binding) do
      {:ok, Map.put(grant, :host_key, Agent.get(config.agent, &Map.get(&1, :host_key, key)))}
    end
  end

  def renew(config, _, binding) do
    send(config.owner, :renewing)

    case Agent.get(config.agent, & &1) do
      %{renew: :allow, ttl: ttl} ->
        {:ok, %{binding: binding, ttl: ttl}}

      %{renew: :hang} ->
        receive do
          :never -> {:error, :denied}
        end

      _ ->
        {:error, :denied}
    end
  end
end
