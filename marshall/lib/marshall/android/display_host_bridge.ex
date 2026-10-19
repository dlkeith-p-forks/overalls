defmodule Marshall.Android.DisplayHostBridge do
  @moduledoc "Bridges a Lilly host stream's Android display messages into a display relay."
  use GenServer

  @spec start_link(pid(), GenServer.server(), pos_integer()) :: GenServer.on_start()
  def start_link(host_stream, relay, generation),
    do: GenServer.start_link(__MODULE__, {host_stream, relay, generation})

  @spec frame(GenServer.server(), pos_integer(), binary()) :: :ok
  def frame(bridge, generation, bytes), do: GenServer.cast(bridge, {:frame, generation, bytes})

  @spec input(GenServer.server(), pid(), binary()) :: :ok
  def input(bridge, viewer, bytes), do: GenServer.cast(bridge, {:input, viewer, bytes})

  @impl true
  def init({host_stream, relay, generation})
      when is_pid(host_stream) and is_integer(generation) and generation > 0,
      do: begin_bridge(host_stream, relay, generation)

  @impl true
  def handle_cast({:frame, generation, bytes}, %{generation: generation} = state)
      when is_binary(bytes) and byte_size(bytes) in 1..262_144 do
    _ = Marshall.Android.DisplayRelay.frame(state.relay, generation, bytes)
    {:noreply, state}
  end

  def handle_cast({:frame, _generation, _bytes}, state), do: {:noreply, state}

  def handle_cast({:input, viewer, bytes}, state)
      when is_pid(viewer) and is_binary(bytes) and byte_size(bytes) in 1..4096 do
    _ = Marshall.Android.DisplayRelay.input(state.relay, viewer, state.generation, bytes)
    {:noreply, state}
  end

  def handle_cast(_, state), do: {:noreply, state}

  defp begin_bridge(host_stream, relay, generation) do
    with :ok <- Marshall.Android.DisplayRelay.set_input_sink(relay, host_stream) do
      {:ok, %{host_stream: host_stream, relay: relay, generation: generation}}
    else
      _ -> {:stop, :relay_unavailable}
    end
  end
end
