defmodule Marshall.Android.DisplayRelay do
  @moduledoc "Generation-fenced Android display viewer/controller relay state machine."
  use GenServer

  @type mode :: :viewer | :controller
  @type state :: %{
          generation: pos_integer(),
          viewers: %{pid() => reference()},
          controller: pid() | nil,
          sequence: non_neg_integer()
        }

  @spec start_link(pos_integer()) :: GenServer.on_start()
  def start_link(generation), do: GenServer.start_link(__MODULE__, generation)

  @spec attach(GenServer.server(), pid(), mode()) :: :ok | {:error, atom()}
  def attach(relay, pid, mode), do: GenServer.call(relay, {:attach, pid, mode})

  @spec detach(GenServer.server(), pid()) :: :ok
  def detach(relay, pid), do: GenServer.call(relay, {:detach, pid})

  @spec frame(GenServer.server(), pos_integer(), binary()) :: :ok | {:error, atom()}
  def frame(relay, generation, bytes), do: GenServer.call(relay, {:frame, generation, bytes})

  @spec input(GenServer.server(), pid(), pos_integer(), binary()) :: :ok | {:error, atom()}
  def input(relay, pid, generation, bytes),
    do: GenServer.call(relay, {:input, pid, generation, bytes})

  @impl true
  def init(generation) when is_integer(generation) and generation > 0,
    do: {:ok, %{generation: generation, viewers: %{}, controller: nil, sequence: 0}}

  @impl true
  def handle_call({:attach, pid, :viewer}, _from, state),
    do: {:reply, :ok, monitor_put(state, pid)}

  def handle_call({:attach, pid, :controller}, _from, %{controller: nil} = state),
    do: {:reply, :ok, %{monitor_put(state, pid) | controller: pid}}

  def handle_call({:attach, _pid, :controller}, _from, state),
    do: {:reply, {:error, :controller_busy}, state}

  def handle_call({:attach, _pid, _mode}, _from, state),
    do: {:reply, {:error, :invalid_mode}, state}

  def handle_call({:detach, pid}, _from, state), do: {:reply, :ok, remove(state, pid)}

  def handle_call({:frame, generation, bytes}, _from, %{generation: generation} = state)
      when is_binary(bytes) and byte_size(bytes) in 1..262_144 do
    sequence = state.sequence + 1

    Enum.each(
      Map.keys(state.viewers),
      &send(&1, {:android_display_frame, generation, sequence, bytes})
    )

    {:reply, :ok, %{state | sequence: sequence}}
  end

  def handle_call({:frame, _generation, _bytes}, _from, state),
    do: {:reply, {:error, :stale_generation}, state}

  def handle_call(
        {:input, pid, generation, bytes},
        _from,
        %{controller: pid, generation: generation} = state
      )
      when is_binary(bytes) and byte_size(bytes) in 1..4096 do
    send(pid, {:android_display_input_accepted, generation, bytes})
    {:reply, :ok, state}
  end

  def handle_call({:input, _pid, _generation, _bytes}, _from, state),
    do: {:reply, {:error, :input_denied}, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case Map.get(state.viewers, pid) do
      ^monitor -> {:noreply, remove(state, pid)}
      _ -> {:noreply, state}
    end
  end

  defp monitor_put(state, pid) do
    if Map.has_key?(state.viewers, pid),
      do: state,
      else: %{state | viewers: Map.put(state.viewers, pid, Process.monitor(pid))}
  end

  defp remove(state, pid) do
    if monitor = Map.get(state.viewers, pid), do: Process.demonitor(monitor, [:flush])

    %{
      state
      | viewers: Map.delete(state.viewers, pid),
        controller: if(state.controller == pid, do: nil, else: state.controller)
    }
  end
end
