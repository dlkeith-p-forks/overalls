defmodule Marshall.Android.DisplayRegistry do
  @moduledoc "Machine and generation scoped Android display relays."
  use GenServer
  @type key :: {String.t(), pos_integer()}
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  @spec relay(key()) :: {:ok, pid()} | {:error, term()}
  def relay(key), do: GenServer.call(__MODULE__, {:relay, key})

  @spec bridge(key(), pid(), map()) :: {:ok, pid()} | {:error, term()}
  def bridge(key, host_stream, open_message),
    do: GenServer.call(__MODULE__, {:bridge, key, host_stream, open_message})

  @impl true
  def init(_state), do: {:ok, %{relays: %{}, bridges: %{}}}
  @impl true
  def handle_call({:relay, {machine_id, generation} = key}, _from, state)
      when is_binary(machine_id) and byte_size(machine_id) in 1..256 and is_integer(generation) and
             generation > 0 do
    case Map.get(state.relays, key) do
      pid when is_pid(pid) ->
        if Process.alive?(pid),
          do: {:reply, {:ok, pid}, state},
          else: start_relay(key, generation, state)

      _ ->
        start_relay(key, generation, state)
    end
  end

  def handle_call(
        {:bridge, {machine_id, generation} = key, host_stream, open_message},
        _from,
        state
      )
      when is_binary(machine_id) and is_pid(host_stream) and is_map(open_message) and
             is_integer(generation) and generation > 0 do
    case state.bridges[key] do
      bridge when is_pid(bridge) ->
        if Process.alive?(bridge) do
          {:reply, {:ok, bridge}, state}
        else
          start_bridge(key, generation, host_stream, open_message, state)
        end

      _ ->
        start_bridge(key, generation, host_stream, open_message, state)
    end
  end

  defp start_bridge(key, generation, host_stream, open_message, state) do
    with {:ok, relay, state} <- relay_for_state(key, generation, state),
         {:ok, bridge} <-
           Marshall.Android.DisplayHostBridge.start_link(
             host_stream,
             relay,
             generation,
             open_message
           ) do
      {:reply, {:ok, bridge}, put_in(state, [:bridges, key], bridge)}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :invalid_key}, state}

  defp start_relay(key, generation, state) do
    case Marshall.Android.DisplayRelay.start_link(generation) do
      {:ok, pid} -> {:reply, {:ok, pid}, put_in(state, [:relays, key], pid)}
      error -> {:reply, error, state}
    end
  end

  defp relay_for_state(key, generation, state) do
    case state.relays[key] do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid, state}, else: {:error, :relay_unavailable}

      _ ->
        case Marshall.Android.DisplayRelay.start_link(generation) do
          {:ok, pid} -> {:ok, pid, put_in(state, [:relays, key], pid)}
          error -> error
        end
    end
  end
end
