defmodule Porsche.Observability do
  @moduledoc "Fixed aggregate metrics; diagnostics hold no connection or domain authority."
  use GenServer
  require Porsche.Events
  alias Porsche.SLO

  @events [
    [:porsche, :http, :complete],
    [:porsche, :ssh, :complete],
    [:porsche, :ssh, :candidate],
    [:porsche, :ssh, :proved]
  ]
  @maximum 9_007_199_254_740_991
  @slo_table __MODULE__.SLO
  @proof_table __MODULE__.Proofs
  @slo_counters {:slo, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
  @names ~w(http_count http_duration_ms http_errors ssh_count ssh_duration_ms ssh_errors ssh_candidate_total ssh_proved_total beam_memory_bytes beam_processes beam_atoms beam_run_queue)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:named_table, :public, write_concurrency: true])
    :ets.new(@slo_table, [:named_table, :public, write_concurrency: true])
    :ets.new(@proof_table, [:named_table, :public, write_concurrency: true])
    :ets.insert(@slo_table, @slo_counters)
    :telemetry.detach(__MODULE__)
    :ok = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.observe/4, nil)
    Process.send_after(self(), :report, 60_000)
    Process.send_after(self(), :slo_publish, 5_000)
    {:ok, %{slo: SLO.new(), slo_path: System.get_env("PORSCHE_SLO_SNAPSHOT")}}
  end

  # @cc [owner:ghuntley,label:security;capacity] porsche-fixed-metric-storage
  # Aggregation MUST retain only fixed event keys and bounded numeric values.
  # Peer identifiers, commands, credentials, exception data and metadata MUST NOT
  # enter storage. Missing diagnostic infrastructure MUST NOT fail a command.
  @spec observe([atom()], map(), map(), term()) :: :ok
  def observe([:porsche, :ssh, :candidate], %{count: count}, _metadata, _),
    do: counted(:ssh_candidate, count)

  def observe([:porsche, :ssh, :proved], %{count: count}, _metadata, _),
    do: counted(:ssh_proved, count)

  def observe([:porsche, kind, :complete], measurements, _metadata, _)
      when kind in [:http, :ssh] do
    duration = Map.get(measurements, :duration_us, 0)
    duration = if is_integer(duration) and duration in 0..@maximum, do: duration, else: 0
    error = if Map.get(measurements, :error) == 1, do: 1, else: 0

    :ets.update_counter(
      __MODULE__,
      kind,
      [
        {2, 1, @maximum, @maximum},
        {3, duration, @maximum, @maximum},
        {4, error, @maximum, @maximum}
      ],
      {kind, 0, 0, 0}
    )

    if kind == :ssh and Map.get(measurements, :eligible) in [true, 1],
      do: record_slo(error, duration)

    :ok
  rescue
    ArgumentError -> :ok
  end

  def observe(_, _, _, _), do: :ok

  # @cc [owner:ghuntley,label:reliability] porsche-ssh-slo-denominator
  # A terminal SSH result with exit status 2 or 3 MUST stay outside the
  # candidate denominator. Other terminal results and caught crashes MUST
  # submit one outcome to the observer when it is available.
  # HTTP client timing MUST NOT become an SSH command outcome.
  @spec measure(:http | :ssh, (-> result)) :: result when result: term()
  def measure(kind, function) when kind in [:http, :ssh] do
    started = System.monotonic_time(:microsecond)

    ticket =
      if kind == :ssh,
        do: Overalls.RequestAccounting.Producer.admit(Porsche.RequestRecorder),
        else: :unrecorded

    try do
      result = function.()

      error =
        case result do
          {:error, _} -> 1
          %{exit_status: status} when status != 0 -> 1
          _ -> 0
        end

      eligible =
        case result do
          %{exit_status: status} when status in [2, 3] -> false
          _ -> true
        end

      completed(kind, started, error, eligible)

      Overalls.RequestAccounting.Producer.complete(
        Porsche.RequestRecorder,
        ticket,
        cond do
          not eligible -> :exclude
          error == 0 -> :success
          true -> :failure
        end,
        max(System.monotonic_time(:microsecond) - started, 0)
      )

      result
    catch
      category, reason ->
        Overalls.RequestAccounting.Producer.complete(
          Porsche.RequestRecorder,
          ticket,
          :failure,
          max(System.monotonic_time(:microsecond) - started, 0)
        )

        completed(kind, started, 1, true)
        :erlang.raise(category, reason, __STACKTRACE__)
    end
  end

  defp completed(kind, started, error, eligible) do
    Overalls.Diagnostics.Metrics.record(
      [:porsche, kind, :complete],
      %{
        duration_us: max(System.monotonic_time(:microsecond) - started, 0),
        error: error,
        eligible: eligible
      },
      %{}
    )
  end

  # @cc [owner:ghuntley,label:capacity;reliability] porsche-slo-fixed-atomic-storage
  # An eligible completion MUST update one fixed numeric histogram row directly,
  # with no per-completion mailbox message. Concurrent producers MUST add one
  # outcome and one bucket atomically; identities and command data MUST NOT enter
  # the row. An unavailable table MUST preserve the command result.
  @spec record_slo(0 | 1, non_neg_integer()) :: :ok
  defp record_slo(error, duration_us) do
    :ets.update_counter(
      @slo_table,
      :slo,
      [
        {2, 1},
        {3, if(error == 0, do: 1, else: 0)},
        {4, error},
        {5, duration_us},
        {6 + SLO.bucket_index(duration_us), 1}
      ],
      @slo_counters
    )

    :ok
  end

  defp counted(key, count) do
    increment = if is_integer(count) and count in 0..@maximum, do: count, else: 0

    :ets.update_counter(@proof_table, key, [{2, increment, @maximum, @maximum}], {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec slo_snapshot() :: SLO.snapshot()
  def slo_snapshot, do: GenServer.call(__MODULE__, :slo_snapshot)

  @impl true
  def handle_call(:slo_snapshot, _from, state),
    do: {:reply, SLO.snapshot(current_slo(state.slo)), state}

  @spec snapshot() :: map()
  def snapshot do
    Enum.reduce([:http, :ssh], %{}, fn key, metrics ->
      case :ets.take(__MODULE__, key) do
        [{^key, count, duration, errors}] ->
          Map.merge(metrics, %{
            "#{key}_count" => count,
            "#{key}_duration_ms" => duration / 1000,
            "#{key}_errors" => errors
          })

        [] ->
          metrics
      end
    end)
    |> Map.merge(proofs())
    |> Map.merge(%{
      "beam_memory_bytes" => :erlang.memory(:total),
      "beam_processes" => :erlang.system_info(:process_count),
      "beam_atoms" => :erlang.system_info(:atom_count),
      "beam_run_queue" => :erlang.statistics(:total_run_queue_lengths)
    })
  end

  defp proofs do
    Map.new(
      [ssh_candidate: "ssh_candidate_total", ssh_proved: "ssh_proved_total"],
      fn {key, name} ->
        case :ets.lookup(@proof_table, key) do
          [{^key, total}] -> {name, total}
          [] -> {name, 0}
        end
      end
    )
  end

  @spec current_slo(SLO.t()) :: SLO.t()
  defp current_slo(identity) do
    case :ets.lookup(@slo_table, :slo) do
      [{:slo, requests, successes, failures, duration, b0, b1, b2, b3, b4, b5, b6, b7}] ->
        %{
          identity
          | requests: requests,
            successes: successes,
            failures: failures,
            duration_count: requests,
            duration_sum_us: duration,
            bucket_counts: {b0, b1, b2, b3, b4, b5, b6, b7}
        }

      [] ->
        identity
    end
  end

  # @cc [owner:ghuntley,label:security] porsche-metric-report-allowlist
  # Reports reaching logger handlers MUST contain only fixed metric names and
  # bounded nonnegative numbers, regardless of caller-supplied report metadata.
  @spec sanitize(map()) :: map()
  def sanitize(metrics) do
    metrics
    |> Map.take(@names)
    |> Map.filter(fn {_key, value} -> is_number(value) and value >= 0 and value <= @maximum end)
  end

  @impl true
  def handle_info(:report, state) do
    metrics = sanitize(snapshot())

    Porsche.Events.emit("porsche.runtime_metrics",
      http_count: metric_value(metrics, "http_count", 1),
      http_duration_us: metric_value(metrics, "http_duration_ms", 1000),
      http_errors: metric_value(metrics, "http_errors", 1),
      ssh_count: metric_value(metrics, "ssh_count", 1),
      ssh_duration_us: metric_value(metrics, "ssh_duration_ms", 1000),
      ssh_errors: metric_value(metrics, "ssh_errors", 1),
      ssh_candidate_total: metric_value(metrics, "ssh_candidate_total", 1),
      ssh_proved_total: metric_value(metrics, "ssh_proved_total", 1),
      beam_memory_bytes: metric_value(metrics, "beam_memory_bytes", 1),
      beam_processes: metric_value(metrics, "beam_processes", 1),
      beam_atoms: metric_value(metrics, "beam_atoms", 1),
      beam_run_queue: metric_value(metrics, "beam_run_queue", 1)
    )

    Process.send_after(self(), :report, 60_000)
    {:noreply, state}
  end

  # @cc [owner:ghuntley,label:observability;reliability] porsche-slo-publication-transitions
  # Snapshot write failures MUST preserve request handling and emit only one
  # payload-free failure per unavailable interval, followed by one recovery
  # after a successful replacement. Paths and raw IO errors MUST NOT be logged.
  def handle_info(:slo_publish, state) do
    outcome = publish_slo(state)
    previous = Map.get(state, :publication, :ok)

    if outcome != previous do
      case outcome do
        :error ->
          Porsche.Events.emit("porsche.slo_publication_failed", [])

        :ok when previous == :error ->
          Porsche.Events.emit("porsche.slo_publication_recovered", [])

        _ ->
          :ok
      end
    end

    Process.send_after(self(), :slo_publish, 5_000)
    {:noreply, Map.put(state, :publication, outcome)}
  end

  # @cc [owner:ghuntley,label:security;reliability] porsche-private-slo-file
  # Publication MUST replace a fixed numeric snapshot atomically in Porsche's
  # private runtime directory. Write failure MUST NOT interrupt SSH commands.
  defp publish_slo(%{slo_path: nil}), do: :disabled

  defp publish_slo(%{slo_path: path, slo: slo}) do
    staged = path <> ".new"

    with :ok <- File.write(staged, JSON.encode!(SLO.snapshot(current_slo(slo)))),
         :ok <- File.chmod(staged, 0o600),
         :ok <- File.rename(staged, path) do
      :ok
    else
      _ -> :error
    end
  end

  @impl true
  def terminate(_, _), do: :telemetry.detach(__MODULE__)
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
