defmodule Brady.Metrics do
  @moduledoc "Bounded aggregate counters and private fleet-monitor and SLO snapshots."
  use GenServer
  require Brady.Events
  alias Overalls.RequestAccounting.Aggregate
  @key {__MODULE__, :counters}
  @names ~w(requests errors cache_hits cache_misses cache_bypasses bytes_received bytes_sent duration_us)
  @maximum 9_223_372_036_854_775_807
  @slo_offset length(@names)
  @duration_bounds_us Aggregate.bounds()
  @bucket_offset @slo_offset + 5
  @slot_count @bucket_offset + length(@duration_bounds_us) + 1

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # @cc [owner:ghuntley,label:security;capacity] brady-aggregate-metrics
  # Request observations MUST retain only fixed numeric aggregates, never request
  # identities or text. Updating metrics MUST NOT enqueue per-request messages.
  @spec request(map()) :: :ok
  def request(fields) do
    case :persistent_term.get(@key, nil) do
      nil ->
        :ok

      ref ->
        increments = [
          1,
          if(fields[:reason] == :ok, do: 0, else: 1),
          if(fields[:cache] == :hit, do: 1, else: 0),
          if(fields[:cache] == :miss, do: 1, else: 0),
          if(fields[:cache] == :bypass, do: 1, else: 0),
          fields[:bytes_received],
          fields[:bytes_sent],
          fields[:duration_us]
        ]

        Enum.with_index(increments, 1)
        |> Enum.each(fn {value, index} ->
          if is_integer(value) and value >= 0 and value <= @maximum,
            do: increment(ref, index, value)
        end)

        record_slo(ref, fields)

        :ok
    end
  end

  @spec snapshot() :: map()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @spec slo_snapshot() :: map() | nil
  def slo_snapshot, do: GenServer.call(__MODULE__, :slo_snapshot)

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, counters(state.ref), state}

  def handle_call(:slo_snapshot, _, state), do: {:reply, slo_counters(state.ref), state}

  # @cc [owner:ghuntley,label:security;reliability] brady-slo-admitted-outcomes
  # Only resolved, admitted requests may enter the SLO denominator. Expected
  # policy and malformed-request refusals MUST NOT improve or burn its budget.
  # Each terminal outcome is counted once, with fixed duration buckets only.
  defp record_slo(ref, fields) do
    reason = fields[:reason]

    if fields[:attribution] == :resolved and fields[:slo_admitted] == :yes and
         reason in [
           :ok,
           :upstream,
           :invalid_http,
           :tls,
           :timeout,
           :capacity,
           :storage,
           :internal,
           :transport,
           :closed
         ] do
      if reason == :ok,
        do: increment(ref, @slo_offset + 2, 1),
        else: increment(ref, @slo_offset + 3, 1)

      duration = fields[:duration_us]

      if is_integer(duration) and duration >= 0 and duration <= @maximum do
        bucket = Aggregate.bucket_index(duration)

        increment(ref, @bucket_offset + bucket + 1, 1)
        increment(ref, @slo_offset + 4, 1)
        increment(ref, @slo_offset + 5, duration)
      end

      increment(ref, @slo_offset + 1, 1)
    end
  end

  defp increment(ref, index, value) do
    current = :atomics.get(ref, index)

    case :atomics.compare_exchange(ref, index, current, min(current + value, @maximum)) do
      :ok -> :ok
      _ -> increment(ref, index, value)
    end
  end

  @impl true
  def init(opts) do
    ref = :atomics.new(@slot_count, signed: false)
    :persistent_term.put(@key, ref)

    state = %{
      ref: ref,
      path: Keyword.get(opts, :path),
      slo_path: Keyword.get(opts, :slo_path),
      started_at_unix_nano: System.system_time(:nanosecond),
      cache: Keyword.get(opts, :cache),
      invocation: Keyword.get(opts, :invocation),
      incarnation: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    }

    send(self(), :publish)
    {:ok, state}
  end

  @impl true
  def handle_info(:publish, state) do
    if is_binary(state.path) do
      snapshot = %{
        version: 1,
        sampled_at: System.system_time(:second),
        incarnation: state.incarnation,
        invocation_id: state.invocation,
        counters: counters(state.ref),
        gauges: gauges(state.cache)
      }

      # Atomic rename prevents the collector observing a partially written document.
      temporary = state.path <> ".tmp"

      with :ok <- File.write(temporary, JSON.encode!(snapshot), [:binary]),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- File.rename(temporary, state.path) do
        :ok
      else
        {:error, reason} ->
          Brady.Events.emit("brady.metrics_publish_failed", reason: publish_loss(reason))
      end
    end

    if is_binary(state.slo_path) do
      case slo_counters(state.ref) do
        nil ->
          :ok

        values ->
          snapshot =
            Map.merge(values, %{
              version: 1,
              service: "brady",
              sampled_at_unix_nano: System.system_time(:nanosecond),
              started_at_unix_nano: state.started_at_unix_nano,
              incarnation: state.incarnation,
              invocation_id: state.invocation
            })

          case Aggregate.validate_snapshot(snapshot) do
            {:error, _reason} ->
              Brady.Events.emit("brady.metrics_publish_failed", reason: :invalid_snapshot)

            :ok ->
              publish_slo(state.slo_path, snapshot)
          end
      end
    end

    Process.send_after(self(), :publish, 5_000)
    {:noreply, state}
  end

  defp publish_slo(path, snapshot) do
    case private_write(path, snapshot) do
      :ok ->
        :ok

      {:error, reason} ->
        Brady.Events.emit("brady.metrics_publish_failed", reason: publish_loss(reason))
    end
  end

  defp publish_loss(reason) when reason in [:enospc, :edquot, :efbig], do: :full
  defp publish_loss(reason) when reason in [:eacces, :eperm, :erofs], do: :permission
  defp publish_loss(reason) when reason in [:enoent, :enotdir, :eisdir, :enametoolong], do: :path
  defp publish_loss(_), do: :io

  @impl true
  def format_status(status),
    do: Map.new(status, fn {key, _} -> {key, if(key == :log, do: [], else: :redacted)} end)

  defp counters(ref) do
    @names
    |> Enum.with_index(1)
    |> Map.new(fn {name, index} -> {name, min(:atomics.get(ref, index), @maximum)} end)
  end

  defp slo_counters(ref, attempts \\ 3)

  defp slo_counters(_ref, 0), do: nil

  defp slo_counters(ref, attempts) do
    requests = :atomics.get(ref, @slo_offset + 1)
    successes = :atomics.get(ref, @slo_offset + 2)
    failures = :atomics.get(ref, @slo_offset + 3)
    duration_count = :atomics.get(ref, @slo_offset + 4)
    duration_sum_us = :atomics.get(ref, @slo_offset + 5)

    buckets =
      for index <- 1..(length(@duration_bounds_us) + 1),
          do: :atomics.get(ref, @bucket_offset + index)

    if requests == successes + failures and duration_count <= requests and
         duration_count == Enum.sum(buckets) do
      %{
        requests: requests,
        successes: successes,
        failures: failures,
        duration: %{
          count: duration_count,
          sum_us: duration_sum_us,
          explicit_bounds_us: @duration_bounds_us,
          bucket_counts: buckets
        }
      }
    else
      slo_counters(ref, attempts - 1)
    end
  end

  defp private_write(path, value) do
    temporary = path <> ".tmp"

    with :ok <- File.write(temporary, JSON.encode!(value), [:binary]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    end
  end

  defp gauges(nil), do: %{}

  defp gauges(cache) do
    stats = Brady.Cache.Store.stats(cache)

    %{
      cache_used_bytes: stats.used,
      cache_pending_bytes: stats.pending,
      cache_objects: stats.objects,
      cache_writers: stats.writers,
      cache_readers: stats.readers,
      cache_writable: if(stats.writable, do: 1, else: 0)
    }
  catch
    :exit, _ -> %{}
  end
end
