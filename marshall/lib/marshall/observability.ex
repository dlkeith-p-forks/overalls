defmodule Marshall.Observability do
  @moduledoc "Bounded aggregate diagnostics; no request metadata or durable domain authority."
  use GenServer
  require Marshall.Events

  @events [
    {[:phoenix, :endpoint, :stop], :http, :duration, :http},
    {[:marshall, :control, :request], :control, :duration, :http},
    {[:marshall, :ssh, :request], :ssh, :duration, :http},
    {[:marshall, :terminal, :authority], :terminal_authority, :duration, :http},
    {[:marshall, :terminal, :input], :terminal_input, :duration, :none},
    {[:marshall, :repo, :query], :database, :total_time, :database},
    {[:marshall, :repo, :query], :database_queue, :queue_time, :none},
    {[:oban, :job, :stop], :jobs, :duration, :none},
    {[:oban, :job, :exception], :job_failures, :duration, :exception}
  ]

  @live_views [:overview, :machines, :machine_new, :machine]
  @live_keys Enum.map(@live_views, &:"live_#{&1}")

  @metric_names Enum.uniq(
                  for {_, key, _, _} <- @events,
                      suffix <- ~w(count duration_ms errors),
                      do: "#{key}_#{suffix}"
                ) ++
                  Enum.flat_map(
                    @live_keys,
                    &["#{&1}_count", "#{&1}_duration_ms", "#{&1}_queries"]
                  ) ++
                  ~w(beam_memory_bytes beam_processes beam_atoms beam_run_queue terminal_host_streams terminal_viewer_sockets terminal_peer_sockets)

  # @cc [owner:ghuntley,label:security] metric-summary-numeric-allowlist
  # Metric summaries MUST contain only the fixed observation names and bounded,
  # nonnegative numbers. Arbitrary report values MUST NOT reach log handlers.
  @spec sanitize_metrics(map()) :: map()
  def sanitize_metrics(metrics) do
    metrics
    |> Map.take(@metric_names)
    |> Map.filter(fn {_key, value} ->
      is_number(value) and value >= 0 and value <= 9_007_199_254_740_991
    end)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    :ets.new(__MODULE__, [:named_table, :public, write_concurrency: true])
    :telemetry.detach(__MODULE__)

    :ok =
      :telemetry.attach_many(
        __MODULE__,
        Enum.uniq([[:marshall, :live, :refresh] | Enum.map(@events, &elem(&1, 0))]),
        &__MODULE__.observe/4,
        nil
      )

    Process.send_after(self(), :report, 60_000)
    {:ok, nil}
  end

  # @cc [owner:ghuntley,label:security;capacity] aggregate-metrics-bounded-identities
  # The handler MUST retain only fixed event keys and numeric counts/durations.
  # Request, user, VM, query, job arguments and terminal data MUST NOT enter its table.
  @spec observe([atom()], map(), map(), term()) :: :ok
  def observe([:marshall, :live, :refresh], measurements, %{view: view}, _config)
      when view in @live_views do
    with %{duration: duration, queries: queries}
         when is_integer(duration) and duration >= 0 and is_integer(queries) and queries >= 0 <-
           measurements do
      key = :"live_#{view}"

      :ets.update_counter(
        __MODULE__,
        key,
        [{2, 1}, {3, System.convert_time_unit(duration, :native, :microsecond)}, {4, queries}],
        {key, 0, 0, 0}
      )
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def observe([:marshall, :live, :refresh], _measurements, _metadata, _config), do: :ok

  def observe(event, measurements, metadata, _config) do
    if event == [:marshall, :repo, :query], do: count_query()

    for {^event, key, measurement, classifier} <- @events do
      value = Map.get(measurements, measurement, 0)

      duration =
        if is_integer(value) and value >= 0,
          do: System.convert_time_unit(value, :native, :microsecond),
          else: 0

      error = error_count(classifier, metadata)

      :ets.update_counter(__MODULE__, key, [{2, 1}, {3, duration}, {4, error}], {key, 0, 0, 0})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec error_count(:http | :database | :exception | :none, map()) :: 0 | 1
  defp error_count(:exception, _metadata), do: 1
  defp error_count(:none, _metadata), do: 0

  defp error_count(:http, metadata) do
    case metadata do
      %{conn: %{status: status}} when is_integer(status) and status >= 500 -> 1
      %{status: status} when is_integer(status) and status >= 500 -> 1
      _ -> 0
    end
  end

  defp error_count(:database, %{result: {:error, _}}), do: 1
  defp error_count(:database, _metadata), do: 0

  @spec snapshot() :: map()
  def snapshot do
    snapshot(:interval)
  end

  @doc "Returns current aggregate counters without consuming the reporting interval."
  @spec snapshot(:interval | :current) :: map()
  def snapshot(mode) when mode in [:interval, :current] do
    metrics =
      @events
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.reduce(%{}, fn key, acc ->
        case if(mode == :interval,
               do: :ets.take(__MODULE__, key),
               else: :ets.lookup(__MODULE__, key)
             ) do
          [{^key, count, duration, errors}] ->
            acc
            |> Map.put("#{key}_count", count)
            |> Map.put("#{key}_duration_ms", duration / 1000)
            |> Map.put("#{key}_errors", errors)

          [] ->
            acc
        end
      end)

    metrics =
      Enum.reduce(@live_keys, metrics, fn key, acc ->
        case if(mode == :interval,
               do: :ets.take(__MODULE__, key),
               else: :ets.lookup(__MODULE__, key)
             ) do
          [{^key, count, duration, queries}] ->
            acc
            |> Map.put("#{key}_count", count)
            |> Map.put("#{key}_duration_ms", duration / 1000)
            |> Map.put("#{key}_queries", queries)

          [] ->
            acc
        end
      end)

    Map.merge(metrics, %{
      "beam_memory_bytes" => :erlang.memory(:total),
      "beam_processes" => :erlang.system_info(:process_count),
      "beam_atoms" => :erlang.system_info(:atom_count),
      "beam_run_queue" => :erlang.statistics(:total_run_queue_lengths),
      "agent_stuck_turns" => stuck_agent_turns()
    })
    |> Map.merge(Marshall.Terminal.Metrics.snapshot())
  end

  @impl true
  def handle_info(:report, state) do
    metrics = sanitize_metrics(snapshot())

    Marshall.Events.emit("marshall.runtime_metrics",
      http_count: metric_value(metrics, "http_count", 1),
      http_duration_us: metric_value(metrics, "http_duration_ms", 1000),
      http_errors: metric_value(metrics, "http_errors", 1),
      control_count: metric_value(metrics, "control_count", 1),
      control_duration_us: metric_value(metrics, "control_duration_ms", 1000),
      control_errors: metric_value(metrics, "control_errors", 1),
      ssh_count: metric_value(metrics, "ssh_count", 1),
      ssh_duration_us: metric_value(metrics, "ssh_duration_ms", 1000),
      ssh_errors: metric_value(metrics, "ssh_errors", 1),
      terminal_authority_count: metric_value(metrics, "terminal_authority_count", 1),
      terminal_authority_duration_us:
        metric_value(metrics, "terminal_authority_duration_ms", 1000),
      terminal_authority_errors: metric_value(metrics, "terminal_authority_errors", 1),
      terminal_input_count: metric_value(metrics, "terminal_input_count", 1),
      terminal_input_duration_us: metric_value(metrics, "terminal_input_duration_ms", 1000),
      terminal_input_errors: metric_value(metrics, "terminal_input_errors", 1),
      database_count: metric_value(metrics, "database_count", 1),
      database_duration_us: metric_value(metrics, "database_duration_ms", 1000),
      database_errors: metric_value(metrics, "database_errors", 1),
      database_queue_count: metric_value(metrics, "database_queue_count", 1),
      database_queue_duration_us: metric_value(metrics, "database_queue_duration_ms", 1000),
      database_queue_errors: metric_value(metrics, "database_queue_errors", 1),
      jobs_count: metric_value(metrics, "jobs_count", 1),
      jobs_duration_us: metric_value(metrics, "jobs_duration_ms", 1000),
      jobs_errors: metric_value(metrics, "jobs_errors", 1),
      job_failures_count: metric_value(metrics, "job_failures_count", 1),
      job_failures_duration_us: metric_value(metrics, "job_failures_duration_ms", 1000),
      job_failures_errors: metric_value(metrics, "job_failures_errors", 1),
      beam_memory_bytes: metric_value(metrics, "beam_memory_bytes", 1),
      beam_processes: metric_value(metrics, "beam_processes", 1),
      beam_atoms: metric_value(metrics, "beam_atoms", 1),
      beam_run_queue: metric_value(metrics, "beam_run_queue", 1),
      agent_stuck_turns: metric_value(metrics, "agent_stuck_turns", 1),
      terminal_host_streams: metric_value(metrics, "terminal_host_streams", 1),
      terminal_viewer_sockets: metric_value(metrics, "terminal_viewer_sockets", 1),
      terminal_peer_sockets: metric_value(metrics, "terminal_peer_sockets", 1),
      live_overview_count: metric_value(metrics, "live_overview_count", 1),
      live_overview_duration_us: metric_value(metrics, "live_overview_duration_ms", 1000),
      live_overview_queries: metric_value(metrics, "live_overview_queries", 1),
      live_machines_count: metric_value(metrics, "live_machines_count", 1),
      live_machines_duration_us: metric_value(metrics, "live_machines_duration_ms", 1000),
      live_machines_queries: metric_value(metrics, "live_machines_queries", 1),
      live_machine_new_count: metric_value(metrics, "live_machine_new_count", 1),
      live_machine_new_duration_us: metric_value(metrics, "live_machine_new_duration_ms", 1000),
      live_machine_new_queries: metric_value(metrics, "live_machine_new_queries", 1),
      live_machine_count: metric_value(metrics, "live_machine_count", 1),
      live_machine_duration_us: metric_value(metrics, "live_machine_duration_ms", 1000),
      live_machine_queries: metric_value(metrics, "live_machine_queries", 1)
    )

    Process.send_after(self(), :report, 60_000)
    {:noreply, state}
  end

  @spec stuck_agent_turns() :: non_neg_integer()
  defp stuck_agent_turns do
    case Ecto.Adapters.SQL.query(
           Marshall.Repo,
           "SELECT count(*) FROM agent_turns WHERE status = 'running' AND started_at < now() - interval '120 seconds'",
           [],
           log: false
         ) do
      {:ok, %{rows: [[count]]}} when is_integer(count) -> count
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @query_count {__MODULE__, :query_count}

  # @cc [owner:ghuntley,label:observability;security] live-refresh-measurement
  # A measured LiveView refresh MUST run its callback exactly once inside one
  # reviewed span, returning its exact result. It MUST record only the closed
  # view label, its duration and the number of database queries its own process
  # issued; query text, parameters, users and machines MUST NOT be recorded.
  @doc "Run a LiveView refresh in a reviewed span and record its duration and query count."
  @spec measure_refresh(:overview | :machines | :machine_new | :machine, (-> result)) :: result
        when result: term()
  def measure_refresh(view, fun) when view in @live_views and is_function(fun, 0) do
    Overalls.Diagnostics.Tracing.with_span("marshall.live.refresh", [view: view], fn ->
      started = System.monotonic_time()
      {result, queries} = count_queries(fun)

      :ok = Overalls.Diagnostics.Tracing.annotate(query_count: queries)

      _ =
        Overalls.Diagnostics.Metrics.record(
          [:marshall, :live, :refresh],
          %{duration: System.monotonic_time() - started, queries: queries},
          %{view: view}
        )

      result
    end)
  end

  @doc "Run `fun` and return its result with the database queries this process issued meanwhile."
  @spec count_queries((-> result)) :: {result, non_neg_integer()} when result: term()
  def count_queries(fun) when is_function(fun, 0) do
    outer = Process.get(@query_count)
    Process.put(@query_count, 0)

    try do
      result = fun.()
      {result, Process.get(@query_count, 0)}
    after
      inner = Process.get(@query_count, 0)

      if outer,
        do: Process.put(@query_count, outer + inner),
        else: Process.delete(@query_count)
    end
  end

  @spec count_query() :: :ok
  defp count_query do
    case Process.get(@query_count) do
      count when is_integer(count) -> Process.put(@query_count, count + 1)
      _ -> nil
    end

    :ok
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(__MODULE__)
  # @cc [owner:ghuntley,label:observability;security] runtime-catalogued-numeric-boundary
  # Only reviewed metric names and safe nonnegative integer values may leave this
  # aggregate. Duration conversion MUST preserve microsecond units; values beyond
  # exact OTLP integer range MUST become absent, never become false evidence.
  @spec metric_value(map(), String.t(), pos_integer()) :: non_neg_integer() | nil
  defp metric_value(metrics, key, multiplier) do
    case metrics[key] do
      value
      when is_number(value) and value >= 0 and value <= div(9_007_199_254_740_991, multiplier) ->
        round(value * multiplier)

      _ ->
        nil
    end
  end
end
