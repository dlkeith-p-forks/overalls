defmodule Audi.SLO do
  @moduledoc "Fixed cumulative outcomes for Audi private transport, DNS and SSH."
  use GenServer
  require Audi.Events
  alias Overalls.RequestAccounting.Aggregate

  @bounds_us Aggregate.bounds()

  @type service :: binary()

  @type t :: %{
          service: service(),
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
          service: service(),
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

  # @cc [owner:ghuntley,label:security;reliability] audi-bound-private-outcome
  # Only requests with a current host binding that enter private forwarding
  # MAY enter this counter. Pre-binding denials and guest OTLP uploads MUST stay outside it.
  # Status 2xx-4xx is a transport completion; 5xx or stream loss is failure.
  # No VM, account, service name, path or payload may become a metric label.
  @spec record(integer() | nil, non_neg_integer()) :: :ok
  def record(status, duration_us) do
    record_outcome(is_integer(status) and status in 200..499, duration_us)
  end

  # @cc [owner:ghuntley,label:reliability] audi-fixed-outcome-recording
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

  @spec new(service()) :: t()
  def new(service \\ "audi_private") when service in ["audi_private", "audi_dns", "audi_ssh"] do
    %{
      service: service,
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
    observe_outcome(state, is_integer(status) and status in 200..499, duration_us)
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
      service: state.service,
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
    service = Keyword.get(opts, :service, "audi_private")
    :ets.new(__MODULE__, [:named_table, :public, {:write_concurrency, true}])
    :ets.insert(__MODULE__, List.to_tuple([:slo | List.duplicate(0, 13)]))
    Process.send_after(self(), :publish, 0)
    {:ok, %{slo: new(service), path: path}}
  end

  @impl true
  # @cc [owner:ghuntley,label:observability;reliability] audi-slo-publication-transitions
  # Snapshot write failures MUST preserve request handling and emit only one
  # payload-free failure per unavailable interval, followed by one recovery
  # after a successful replacement. Paths and raw IO errors MUST NOT be logged.
  def handle_info(:publish, state) do
    outcome = publish(state)
    previous = Map.get(state, :publication, :ok)

    if outcome != previous do
      case outcome do
        :error -> Audi.Events.emit("audi.slo_publication_failed", [])
        :ok when previous == :error -> Audi.Events.emit("audi.slo_publication_recovered", [])
        _ -> :ok
      end
    end

    Process.send_after(self(), :publish, 5_000)
    {:noreply, Map.put(state, :publication, outcome)}
  end

  # @cc [owner:ghuntley,label:capacity;reliability] audi-slo-periodic-snapshot
  # DNS, private transport and SSH observations MUST update memory only.
  # Snapshot file replacement MUST happen on the periodic publisher path,
  # with owner-only mode and fixed fields independent of request volume.
  defp publish(%{path: path, slo: slo}) do
    staged = path <> ".new"
    slo = read_counters(slo)
    snapshot = snapshot(slo)

    mode = if slo.service == "audi_ssh", do: 0o640, else: 0o600

    with :ok <- Aggregate.validate_snapshot(snapshot),
         :ok <- File.write(staged, JSON.encode!(snapshot)),
         :ok <- File.chmod(staged, mode),
         :ok <- File.rename(staged, path) do
      :ok
    else
      _ -> :error
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
end
