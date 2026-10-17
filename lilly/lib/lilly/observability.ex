defmodule Lilly.Observability do
  @moduledoc "Bounded aggregate diagnostics; no request metadata or durable domain authority."
  use GenServer
  require Lilly.Events

  @events [
    {[:lilly, :control, :fenced], :control_fenced, :count},
    {[:lilly, :control, :backoff], :control_errors, :count}
  ]

  @metric_names Enum.uniq(
                  for {_, key, _} <- @events,
                      suffix <- ~w(count duration_ms errors),
                      do: "#{key}_#{suffix}"
                ) ++
                  ~w(beam_memory_bytes beam_processes beam_atoms beam_run_queue)

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
        Enum.uniq(Enum.map(@events, &elem(&1, 0))),
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
  def observe(event, measurements, _metadata, _config) do
    for {^event, key, measurement} <- @events do
      value = Map.get(measurements, measurement, 0)

      duration =
        if measurement == :duration and is_integer(value) and value >= 0,
          do: System.convert_time_unit(value, :native, :microsecond),
          else: 0

      error =
        case Map.get(measurements, :error, 0) do
          1 -> 1
          _ -> 0
        end

      if is_integer(value) and value >= 0 do
        :ets.update_counter(
          __MODULE__,
          key,
          [{2, value}, {3, duration}, {4, error}],
          {key, 0, 0, 0}
        )
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec snapshot() :: map()
  def snapshot do
    metrics =
      @events
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.reduce(%{}, fn key, acc ->
        case :ets.take(__MODULE__, key) do
          [{^key, count, duration, errors}] ->
            acc
            |> Map.put("#{key}_count", count)
            |> Map.put("#{key}_duration_ms", duration / 1000)
            |> Map.put("#{key}_errors", errors)

          [] ->
            acc
        end
      end)

    Map.merge(metrics, %{
      "beam_memory_bytes" => :erlang.memory(:total),
      "beam_processes" => :erlang.system_info(:process_count),
      "beam_atoms" => :erlang.system_info(:atom_count),
      "beam_run_queue" => :erlang.statistics(:total_run_queue_lengths)
    })
  end

  @impl true
  def handle_info(:report, state) do
    metrics = sanitize_metrics(snapshot())

    Lilly.Events.emit("lilly.runtime_metrics",
      control_fenced_count: metric_value(metrics, "control_fenced_count", 1),
      control_fenced_duration_us: metric_value(metrics, "control_fenced_duration_ms", 1000),
      control_fenced_errors: metric_value(metrics, "control_fenced_errors", 1),
      control_errors_count: metric_value(metrics, "control_errors_count", 1),
      control_errors_duration_us: metric_value(metrics, "control_errors_duration_ms", 1000),
      control_errors_errors: metric_value(metrics, "control_errors_errors", 1),
      beam_memory_bytes: metric_value(metrics, "beam_memory_bytes", 1),
      beam_processes: metric_value(metrics, "beam_processes", 1),
      beam_atoms: metric_value(metrics, "beam_atoms", 1),
      beam_run_queue: metric_value(metrics, "beam_run_queue", 1)
    )

    Process.send_after(self(), :report, 60_000)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(__MODULE__)
  # @cc [owner:ghuntley,label:observability;security] runtime-catalogued-numeric-boundary
  # Only reviewed metric names and safe nonnegative integer values may leave this
  # aggregate. Duration conversion MUST preserve microsecond units; values beyond
  # exact OTLP integer range MUST become absent, never saturate into false evidence.
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
