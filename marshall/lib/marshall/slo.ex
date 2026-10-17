defmodule Marshall.SLO do
  @moduledoc "Fixed cumulative outcomes for Marshall browser HTTP requests."
  use GenServer
  alias Overalls.RequestAccounting.Aggregate

  @bounds_us Aggregate.bounds()

  @type t :: %{
          started_at_unix_nano: non_neg_integer(),
          incarnation: binary(),
          requests: non_neg_integer(),
          successes: non_neg_integer(),
          failures: non_neg_integer(),
          duration_count: non_neg_integer(),
          duration_sum_us: non_neg_integer(),
          bucket_counts: tuple()
        }

  @type snapshot :: %{
          version: 1,
          service: binary(),
          sampled_at_unix_nano: non_neg_integer(),
          started_at_unix_nano: non_neg_integer(),
          incarnation: binary(),
          invocation_id: binary(),
          requests: non_neg_integer(),
          successes: non_neg_integer(),
          failures: non_neg_integer(),
          duration: %{
            count: non_neg_integer(),
            sum_us: non_neg_integer(),
            explicit_bounds_us: [non_neg_integer()],
            bucket_counts: [non_neg_integer()]
          }
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # @cc [owner:ghuntley,label:security;reliability] marshall-browser-http-outcome
  # Only browser requests that reach the endpoint telemetry plug MAY enter this
  # candidate denominator. Completed 2xx-4xx responses succeed; 5xx,
  # exception and missing final status fail. Health and pre-telemetry refusals
  # are excluded. No path, request, user, account or VM identity is retained.
  @spec classify(integer() | nil) :: :success | :failure | :exclude
  def classify(status) when is_integer(status) and status in 200..499, do: :success
  def classify(status) when is_integer(status) and status >= 500, do: :failure
  def classify(nil), do: :failure
  def classify(_), do: :exclude

  @spec observe_event([atom()], map(), map(), term()) :: :ok
  def observe_event([:phoenix, :endpoint, :start], _measurements, _metadata, _config) do
    Process.put(
      {__MODULE__, :ticket},
      Overalls.RequestAccounting.Producer.admit(Marshall.RequestRecorder)
    )

    :ok
  end

  def observe_event(event, measurements, metadata, _config) do
    outcome =
      case event do
        [:phoenix, :endpoint, :exception] ->
          :failure

        [:phoenix, :endpoint, :stop] ->
          case metadata do
            %{conn: %{status: status}} -> classify(status)
            _ -> :failure
          end

        _ ->
          :exclude
      end

    duration = Map.get(measurements, :duration, 0)

    ticket = Process.delete({__MODULE__, :ticket}) || :unrecorded
    measured = is_integer(duration) and duration >= 0

    Overalls.RequestAccounting.Producer.complete(
      Marshall.RequestRecorder,
      ticket,
      if(measured, do: outcome, else: :exclude),
      if(measured, do: System.convert_time_unit(duration, :native, :microsecond), else: 0)
    )

    if outcome != :exclude and is_integer(duration) and duration >= 0 do
      record_outcome(
        outcome == :success,
        System.convert_time_unit(duration, :native, :microsecond)
      )
    end

    :ok
  end

  # @cc [owner:ghuntley,label:reliability] marshall-fixed-outcome-recording
  # With a running SLO process, a caller-approved boolean outcome MUST add
  # exactly one cumulative request, one success or failure and one duration
  # bucket to the configured service.
  # The recorder MUST NOT attach query, request, account or VM identity.
  @spec record_outcome(boolean(), non_neg_integer()) :: :ok
  def record_outcome(success?, duration_us)
      when is_boolean(success?) and is_integer(duration_us) and duration_us >= 0 do
    if :ets.whereis(__MODULE__) != :undefined do
      bucket = Aggregate.bucket_index(duration_us)

      try do
        :ets.update_counter(__MODULE__, :slo, [
          {2, 1},
          {3, if(success?, do: 1, else: 0)},
          {4, if(success?, do: 0, else: 1)},
          {5, 1},
          {6, duration_us},
          {7 + bucket, 1}
        ])
      catch
        :error, :badarg -> :ok
      end
    end

    :ok
  end

  @spec new() :: t()
  def new do
    %{
      started_at_unix_nano: System.system_time(:nanosecond),
      incarnation: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      requests: 0,
      successes: 0,
      failures: 0,
      duration_count: 0,
      duration_sum_us: 0,
      bucket_counts: {0, 0, 0, 0, 0, 0, 0, 0}
    }
  end

  @spec observe(t(), integer() | nil, non_neg_integer()) :: t()
  def observe(state, status, duration_us) when is_integer(duration_us) and duration_us >= 0 do
    case classify(status) do
      :exclude -> state
      :success -> observe_outcome(state, true, duration_us)
      :failure -> observe_outcome(state, false, duration_us)
    end
  end

  @spec observe_outcome(t(), boolean(), non_neg_integer()) :: t()
  def observe_outcome(state, success, duration_us)
      when is_boolean(success) and is_integer(duration_us) and duration_us >= 0 do
    bucket = Aggregate.bucket_index(duration_us)

    %{
      state
      | requests: state.requests + 1,
        successes: state.successes + if(success, do: 1, else: 0),
        failures: state.failures + if(success, do: 0, else: 1),
        duration_count: state.duration_count + 1,
        duration_sum_us: state.duration_sum_us + duration_us,
        bucket_counts:
          put_elem(state.bucket_counts, bucket, elem(state.bucket_counts, bucket) + 1)
    }
  end

  @spec snapshot(t()) :: snapshot()
  def snapshot(state) do
    %{
      version: 1,
      service: "marshall_web",
      sampled_at_unix_nano: System.system_time(:nanosecond),
      started_at_unix_nano: state.started_at_unix_nano,
      incarnation: state.incarnation,
      invocation_id: state.incarnation,
      requests: state.requests,
      successes: state.successes,
      failures: state.failures,
      duration: %{
        count: state.duration_count,
        sum_us: state.duration_sum_us,
        explicit_bounds_us: @bounds_us,
        bucket_counts: Tuple.to_list(state.bucket_counts)
      }
    }
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    :ets.new(__MODULE__, [:named_table, :public, {:write_concurrency, true}])
    :ets.insert(__MODULE__, List.to_tuple([:slo | List.duplicate(0, 13)]))
    :telemetry.detach(__MODULE__)

    :ok =
      :telemetry.attach_many(
        __MODULE__,
        [
          [:phoenix, :endpoint, :start],
          [:phoenix, :endpoint, :stop],
          [:phoenix, :endpoint, :exception]
        ],
        &__MODULE__.observe_event/4,
        nil
      )

    Process.send_after(self(), :publish, 0)
    {:ok, %{slo: new(), path: path}}
  end

  @impl true
  def handle_info(:publish, state) do
    publish(state)
    Process.send_after(self(), :publish, 5_000)
    {:noreply, state}
  end

  # @cc [owner:ghuntley,label:capacity;reliability] marshall-slo-periodic-snapshot
  # Browser endpoint observations MUST update memory only.
  # Snapshot file replacement MUST happen on the periodic publisher path,
  # with source-group-read mode and fixed fields independent of request volume.
  defp publish(%{path: path, slo: slo}) do
    if path == nil, do: :ok, else: publish_file(path, slo)
  end

  defp publish_file(path, slo) do
    staged = path <> ".new"
    slo = read_counters(slo)
    snapshot = snapshot(slo)

    with :ok <- Aggregate.validate_snapshot(snapshot),
         :ok <- File.write(staged, JSON.encode!(snapshot)),
         :ok <- File.chmod(staged, 0o640),
         :ok <- File.rename(staged, path) do
      :ok
    else
      _ -> :ok
    end
  end

  defp read_counters(slo) do
    [{:slo, requests, successes, failures, count, sum_us, b0, b1, b2, b3, b4, b5, b6, b7}] =
      :ets.lookup(__MODULE__, :slo)

    %{
      slo
      | requests: requests,
        successes: successes,
        failures: failures,
        duration_count: count,
        duration_sum_us: sum_us,
        bucket_counts: {b0, b1, b2, b3, b4, b5, b6, b7}
    }
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(__MODULE__)
end
