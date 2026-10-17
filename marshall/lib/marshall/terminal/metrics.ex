defmodule Marshall.Terminal.Metrics do
  @moduledoc "Process-owned, numeric terminal gauges for frontend health."
  use GenServer
  @type kind :: :stream | :viewer | :peer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, nil, Keyword.put_new(options, :name, __MODULE__))

  # @cc [owner:ghuntley,label:security;capacity] frontend-terminal-metrics-process-owned
  # Gauge entries MUST contain only monitored PIDs and one closed kind, never
  # credentials or terminal data. Entries MUST be removed on process death and
  # capped at 8192; loss of observations MUST NOT create execution authority.
  @spec opened(kind()) :: :ok
  def opened(kind) when kind in [:stream, :viewer, :peer],
    do: GenServer.cast(__MODULE__, {:opened, self(), kind})

  @spec snapshot() :: %{String.t() => non_neg_integer()}
  def snapshot do
    GenServer.call(__MODULE__, :snapshot, 1000)
  catch
    :exit, _ -> %{}
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_cast({:opened, pid, kind}, state) do
    cond do
      Map.has_key?(state, pid) -> {:noreply, state}
      map_size(state) >= 8192 -> {:noreply, state}
      true -> {:noreply, Map.put(state, pid, {Process.monitor(pid), kind})}
    end
  end

  @impl true
  def handle_call(:snapshot, _, state) do
    counts = Enum.frequencies_by(Map.values(state), &elem(&1, 1))

    {:reply,
     %{
       "terminal_host_streams" => Map.get(counts, :stream, 0),
       "terminal_viewer_sockets" => Map.get(counts, :viewer, 0),
       "terminal_peer_sockets" => Map.get(counts, :peer, 0)
     }, state}
  end

  @impl true
  def handle_info({:DOWN, reference, :process, pid, _}, state) do
    case state[pid] do
      {^reference, _} -> {:noreply, Map.delete(state, pid)}
      _ -> {:noreply, state}
    end
  end
end
