defmodule Lilly.Terminal.Metrics do
  @moduledoc "Bounded terminal observations; never an execution-authority source."
  use GenServer

  @type binding :: %{
          host_id: String.t(),
          placement_id: String.t(),
          execution_epoch: pos_integer(),
          generation: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, nil, Keyword.put_new(options, :name, __MODULE__))

  # @cc [owner:ghuntley,label:security;capacity] terminal-metrics-contain-no-session-data
  # Observations MUST contain only fixed numeric counters and execution IDs.
  # Tokens, usernames, terminal bytes, labels and command arguments MUST NOT
  # enter metrics. Stream entries are process-owned; dial history is capped at
  # 512 entries and expires after five minutes. Missing observation stays absent.
  @spec report(String.t(), non_neg_integer()) :: :ok
  def report(host, channels), do: GenServer.cast(__MODULE__, {:report, self(), host, channels})

  @spec dial(map(), boolean()) :: :ok
  def dial(
        %{host_id: host, placement_id: placement, execution_epoch: epoch, generation: generation},
        success
      )
      when is_boolean(success) and is_integer(epoch) and epoch > 0 and is_integer(generation) and
             generation > 0 do
    if OverallsProtocol.uuid?(host) and OverallsProtocol.uuid?(placement),
      do:
        GenServer.cast(
          __MODULE__,
          {:dial,
           %{
             host_id: host,
             placement_id: placement,
             execution_epoch: epoch,
             generation: generation
           }, success}
        )

    :ok
  end

  def dial(_, _), do: :ok

  @spec proxy_error(String.t()) :: :ok
  def proxy_error(host), do: GenServer.cast(__MODULE__, {:proxy_error, host})

  @spec snapshot(String.t()) :: %{gauges: map(), counters: map(), vms: [map()]}
  def snapshot(host), do: GenServer.call(__MODULE__, {:snapshot, host}, 1000)

  @impl true
  def init(_), do: {:ok, %{streams: %{}, hosts: %{}, vms: %{}}}

  @impl true
  def handle_cast({:report, pid, host, channels}, state)
      when is_integer(channels) and channels in 0..4096 do
    case state.streams[pid] do
      nil when map_size(state.streams) >= 128 ->
        {:noreply, state}

      previous ->
        monitor = if previous, do: previous.monitor, else: Process.monitor(pid)
        entry = %{host: host, channels: channels, monitor: monitor, at: now()}
        {:noreply, %{state | streams: Map.put(state.streams, pid, entry)}}
    end
  end

  def handle_cast({:dial, binding, success}, state) do
    key = {binding.host_id, binding.placement_id, binding.execution_epoch, binding.generation}

    record =
      Map.merge(Map.delete(binding, :host_id), %{
        reachable: if(success, do: 1, else: 0),
        at: now()
      })

    vms =
      state.vms
      |> Map.reject(fn {_, entry} -> now() - entry.at > 300_000 end)
      |> Map.put(key, record)

    vms =
      if map_size(vms) > 512,
        do: Map.delete(vms, elem(Enum.min_by(vms, fn {_, row} -> row.at end), 0)),
        else: vms

    hosts =
      if success, do: state.hosts, else: increment(state.hosts, binding.host_id, :dial_failures)

    {:noreply, %{state | vms: vms, hosts: hosts}}
  end

  def handle_cast({:proxy_error, host}, state),
    do: {:noreply, %{state | hosts: increment(state.hosts, host, :proxy_errors)}}

  @impl true
  def handle_call({:snapshot, host}, _, state) do
    streams = for {_, row} <- state.streams, row.host == host and now() - row.at <= 3000, do: row

    gauges =
      if streams == [],
        do: %{},
        else: %{terminal_live_channels: Enum.sum(Enum.map(streams, & &1.channels))}

    counts = Map.get(state.hosts, host, %{dial_failures: 0, proxy_errors: 0})

    vms =
      for {{source, _, _, _}, row} <- state.vms,
          source == host and now() - row.at <= 300_000,
          do: row |> Map.put(:age_ms, max(now() - row.at, 0)) |> Map.delete(:at)

    {:reply,
     %{
       gauges: gauges,
       counters: %{
         terminal_dial_failures: counts.dial_failures,
         terminal_proxy_errors: counts.proxy_errors
       },
       vms: vms
     }, state}
  end

  @impl true
  def handle_info({:DOWN, reference, :process, pid, _}, state) do
    streams =
      case state.streams[pid] do
        %{monitor: ^reference} -> Map.delete(state.streams, pid)
        _ -> state.streams
      end

    {:noreply, %{state | streams: streams}}
  end

  @spec increment(map(), String.t(), :dial_failures | :proxy_errors) :: map()
  defp increment(hosts, host, key) do
    if Map.has_key?(hosts, host) or map_size(hosts) < 128 do
      entry = Map.get(hosts, host, %{dial_failures: 0, proxy_errors: 0})
      Map.put(hosts, host, Map.update!(entry, key, &min(&1 + 1, 9_223_372_036_854_775_807)))
    else
      hosts
    end
  end

  @spec now() :: integer()
  defp now, do: System.monotonic_time(:millisecond)
end
