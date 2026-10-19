defmodule Marshall.Android.DisplayHostBridge do
  @moduledoc "Bridges a Lilly host stream's Android display messages into a display relay."
  use GenServer

  # @cc [owner:ghuntley,label:security;recovery] android-display-host-bridge
  # The bridge MUST bind one authenticated host stream to one machine generation,
  # forward only bounded opaque RFB bytes, and stop when that host stream exits.

  @spec start_link(pid(), GenServer.server(), pos_integer()) :: GenServer.on_start()
  def start_link(host_stream, relay, generation),
    do: GenServer.start_link(__MODULE__, {host_stream, relay, generation})

  @spec start_link(pid(), GenServer.server(), pos_integer(), map()) :: GenServer.on_start()
  def start_link(host_stream, relay, generation, open_message) when is_map(open_message),
    do: GenServer.start_link(__MODULE__, {host_stream, relay, generation, open_message})

  @spec frame(GenServer.server(), pos_integer(), binary()) :: :ok
  def frame(bridge, generation, bytes), do: GenServer.cast(bridge, {:frame, generation, bytes})

  @spec input(GenServer.server(), pid(), binary()) :: :ok
  def input(bridge, viewer, bytes), do: GenServer.cast(bridge, {:input, viewer, bytes})

  @impl true
  def init({host_stream, relay, generation})
      when is_pid(host_stream) and is_integer(generation) and generation > 0,
      do: begin_bridge(host_stream, relay, generation)

  def init({host_stream, relay, generation, open_message})
      when is_pid(host_stream) and is_integer(generation) and generation > 0 do
    with {:ok, state} <- begin_bridge(host_stream, relay, generation),
         :ok <- Marshall.Android.DisplayRelay.set_input_sink(relay, self()),
         {:ok, opened} <- Marshall.Terminal.Relay.control(host_stream, open_message),
         true <- opened[:ok] == true,
         channel when is_integer(channel) and channel > 0 <- opened[:channel] do
      {:ok, Map.merge(state, %{channel: channel})}
    else
      _ -> {:stop, :display_unavailable}
    end
  end

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

  @impl true
  def handle_info(
        {:android_display_input, _generation, _viewer, bytes},
        %{channel: channel} = state
      ) do
    send(state.host_stream, {:android_display_input, channel, state.generation, bytes})
    {:noreply, state}
  end

  def handle_info({:android_display_frame, generation, _sequence, bytes}, state)
      when is_binary(bytes) and byte_size(bytes) in 1..262_144 do
    _ = Marshall.Android.DisplayRelay.frame(state.relay, generation, bytes)
    {:noreply, state}
  end

  def handle_info(
        {:android_display_closed, channel, generation, _reason},
        %{channel: channel, generation: generation} = state
      ),
      do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{host_monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{host_stream: host_stream, channel: channel}) do
    send(host_stream, {:relay_dispatch, %{type: :android_display_close, channel: channel}})
    :ok
  end

  def terminate(_, _), do: :ok

  defp begin_bridge(host_stream, relay, generation) do
    with :ok <- Marshall.Android.DisplayRelay.set_input_sink(relay, host_stream) do
      {:ok,
       %{
         host_stream: host_stream,
         host_monitor: Process.monitor(host_stream),
         relay: relay,
         generation: generation
       }}
    else
      _ -> {:stop, :relay_unavailable}
    end
  end
end
