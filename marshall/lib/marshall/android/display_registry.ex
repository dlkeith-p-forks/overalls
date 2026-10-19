defmodule Marshall.Android.DisplayRegistry do
  @moduledoc "Machine and generation scoped Android display relays."
  use GenServer
  @type key :: {String.t(), pos_integer()}
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  @spec relay(key()) :: {:ok, pid()} | {:error, term()}
  def relay(key), do: GenServer.call(__MODULE__, {:relay, key})
  @impl true
  def init(state), do: {:ok, state}
  @impl true
  def handle_call({:relay, {machine_id, generation} = key}, _from, state)
      when is_binary(machine_id) and byte_size(machine_id) in 1..256 and is_integer(generation) and
             generation > 0 do
    case Map.get(state, key) do
      pid when is_pid(pid) ->
        if Process.alive?(pid),
          do: {:reply, {:ok, pid}, state},
          else: start_relay(key, generation, state)

      _ ->
        start_relay(key, generation, state)
    end
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :invalid_key}, state}

  defp start_relay(key, generation, state) do
    case Marshall.Android.DisplayRelay.start_link(generation) do
      {:ok, pid} -> {:reply, {:ok, pid}, Map.put(state, key, pid)}
      error -> {:reply, error, state}
    end
  end
end
