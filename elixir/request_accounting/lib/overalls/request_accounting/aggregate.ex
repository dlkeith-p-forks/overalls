defmodule Overalls.RequestAccounting.Aggregate do
  @moduledoc """
  Pure, bounded request outcome accounting shared by the fleet applications.

  The aggregate is deliberately a value, rather than a process. Applications
  choose their own concurrency and publication mechanism while this module
  keeps the denominator, outcome and duration semantics identical.
  """

  @max_counter 9_223_372_036_854_775_807
  @services ~w(audi_private audi_dns audi_ssh brady enrico galileo marshall_web porsche ziggy)
  @bounds_us [10_000, 50_000, 100_000, 500_000, 1_000_000, 5_000_000, 10_000_000]
  @bucket_count length(@bounds_us) + 1
  @snapshot_keys ~w(version service sampled_at_unix_nano started_at_unix_nano incarnation invocation_id requests successes failures duration)
  @duration_keys ~w(count sum_us explicit_bounds_us bucket_counts)
  @options ~w(started_at_unix_nano incarnation invocation_id)

  @typedoc "The fixed cumulative latency histogram slots."
  @type bucket_counts ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @typedoc "The immutable aggregate state retained by an application adapter."
  @type t :: %__MODULE__{
          service: binary(),
          started_at_unix_nano: pos_integer(),
          incarnation: binary(),
          invocation_id: binary(),
          requests: non_neg_integer(),
          successes: non_neg_integer(),
          failures: non_neg_integer(),
          duration_count: non_neg_integer(),
          duration_sum_us: non_neg_integer(),
          bucket_counts: bucket_counts()
        }

  @typedoc "The stable version-one private snapshot representation."
  @type snapshot :: %{
          required(:version) => 1,
          required(:service) => binary(),
          required(:sampled_at_unix_nano) => pos_integer(),
          required(:started_at_unix_nano) => pos_integer(),
          required(:incarnation) => binary(),
          required(:invocation_id) => binary(),
          required(:requests) => non_neg_integer(),
          required(:successes) => non_neg_integer(),
          required(:failures) => non_neg_integer(),
          required(:duration) => %{
            required(:count) => non_neg_integer(),
            required(:sum_us) => non_neg_integer(),
            required(:explicit_bounds_us) => [non_neg_integer()],
            required(:bucket_counts) => [non_neg_integer()]
          }
        }

  @type outcome :: :success | :failure | :exclude
  @type validation_error ::
          :invalid_snapshot
          | :invalid_version
          | :invalid_service
          | :invalid_identity
          | :invalid_counts
          | :invalid_duration
          | :invalid_bounds

  defstruct service: "",
            started_at_unix_nano: 0,
            incarnation: "",
            invocation_id: "",
            requests: 0,
            successes: 0,
            failures: 0,
            duration_count: 0,
            duration_sum_us: 0,
            bucket_counts: {0, 0, 0, 0, 0, 0, 0, 0}

  @doc "Returns the shared explicit latency bounds in microseconds."
  # @cc [owner:ghuntley,label:reliability;security] request-accounting-fixed-bounds
  # Every application aggregate MUST use these eight fixed slots. Bounds MUST
  # remain independent of request identity, payload, service policy and volume.
  @spec bounds() :: [pos_integer()]
  def bounds, do: @bounds_us

  @doc "Returns the maximum value accepted by the private v1 counters."
  @spec max_counter() :: pos_integer()
  def max_counter, do: @max_counter

  @doc "Returns the histogram slot for a non-negative duration in microseconds."
  @spec bucket_index(non_neg_integer()) :: 0..7
  def bucket_index(duration_us) when is_integer(duration_us) and duration_us >= 0 do
    Enum.find_index(@bounds_us, &(duration_us <= &1)) || length(@bounds_us)
  end

  @doc "Creates an empty aggregate for a service and invocation."
  @spec new(binary(), keyword()) :: t()
  def new(service, opts \\ [])

  def new(service, opts) when is_binary(service) and byte_size(service) > 0 and is_list(opts) do
    if service not in @services or not valid_options?(opts) do
      raise ArgumentError, "invalid request accounting configuration"
    end

    started_at = Keyword.get(opts, :started_at_unix_nano, System.system_time(:nanosecond))
    incarnation = Keyword.get_lazy(opts, :incarnation, &new_identity/0)
    invocation_id = Keyword.get(opts, :invocation_id, incarnation)

    if valid_identity?(started_at, incarnation, invocation_id) do
      %__MODULE__{
        service: service,
        started_at_unix_nano: started_at,
        incarnation: incarnation,
        invocation_id: invocation_id
      }
    else
      raise ArgumentError, "invalid request accounting identity"
    end
  end

  def new(_service, _opts), do: raise(ArgumentError, "invalid request accounting configuration")

  @doc "Records one terminal outcome, optionally with a measured duration."
  # @cc [owner:ghuntley,label:reliability] request-accounting-outcome-conservation
  # A success or failure MUST increment exactly one request and corresponding
  # outcome. An excluded outcome MUST leave all totals unchanged.
  # A missing duration MUST remain unmeasured rather than being recorded as zero.
  @spec record(t(), outcome(), non_neg_integer() | nil) :: t()
  def record(%__MODULE__{} = state, :exclude, _duration_us), do: state

  def record(%__MODULE__{} = state, outcome, duration_us)
      when outcome in [:success, :failure] and
             (is_nil(duration_us) or (is_integer(duration_us) and duration_us >= 0)) do
    if state.requests < @max_counter do
      state
      |> increment_outcome(outcome)
      |> maybe_record_duration(duration_us)
    else
      state
    end
  end

  @doc "Builds a version-one snapshot without exposing identities beyond its stable fields."
  # @cc [owner:ghuntley,label:security;verification] request-accounting-snapshot-schema
  # Snapshots MUST contain only the fixed v1 numeric aggregate shape and stable
  # source identity. Request IDs, payloads, credentials and free-form labels
  # MUST NOT be retained by this value model.
  @spec snapshot(t()) :: snapshot()
  def snapshot(%__MODULE__{} = state) do
    %{
      version: 1,
      service: state.service,
      sampled_at_unix_nano: System.system_time(:nanosecond),
      started_at_unix_nano: state.started_at_unix_nano,
      incarnation: state.incarnation,
      invocation_id: state.invocation_id,
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

  @doc "Validates a version-one snapshot before private publication."
  @spec validate_snapshot(term()) :: :ok | {:error, validation_error()}
  def validate_snapshot(snapshot) when is_map(snapshot) do
    with :ok <- validate_keys(snapshot, @snapshot_keys),
         :ok <- validate_version(snapshot),
         :ok <- validate_identity(snapshot),
         :ok <- validate_counts(snapshot),
         :ok <- validate_duration(snapshot) do
      :ok
    end
  end

  def validate_snapshot(_snapshot), do: {:error, :invalid_snapshot}

  @doc "Returns true when the value is a valid version-one snapshot."
  @spec valid_snapshot?(term()) :: boolean()
  def valid_snapshot?(snapshot), do: validate_snapshot(snapshot) == :ok

  @spec increment_outcome(t(), :success | :failure) :: t()
  defp increment_outcome(state, outcome) do
    %{
      state
      | requests: state.requests + 1,
        successes: state.successes + if(outcome == :success, do: 1, else: 0),
        failures: state.failures + if(outcome == :failure, do: 1, else: 0)
    }
  end

  @spec maybe_record_duration(t(), non_neg_integer() | nil) :: t()
  defp maybe_record_duration(state, nil), do: state

  defp maybe_record_duration(state, duration_us) do
    bucket = bucket_index(duration_us)
    current = elem(state.bucket_counts, bucket)

    if duration_us <= @max_counter and state.duration_count < @max_counter and
         state.duration_sum_us <= @max_counter - duration_us and current < @max_counter do
      %{
        state
        | duration_count: state.duration_count + 1,
          duration_sum_us: state.duration_sum_us + duration_us,
          bucket_counts: put_elem(state.bucket_counts, bucket, current + 1)
      }
    else
      state
    end
  end

  @spec validate_version(map()) :: :ok | {:error, validation_error()}
  defp validate_version(%{version: 1}), do: :ok
  defp validate_version(%{"version" => 1}), do: :ok
  defp validate_version(_), do: {:error, :invalid_version}

  @spec validate_identity(map()) :: :ok | {:error, validation_error()}
  defp validate_identity(snapshot) do
    service = Map.get(snapshot, :service, Map.get(snapshot, "service"))
    sampled = Map.get(snapshot, :sampled_at_unix_nano, Map.get(snapshot, "sampled_at_unix_nano"))
    started = Map.get(snapshot, :started_at_unix_nano, Map.get(snapshot, "started_at_unix_nano"))
    incarnation = Map.get(snapshot, :incarnation, Map.get(snapshot, "incarnation"))
    invocation = Map.get(snapshot, :invocation_id, Map.get(snapshot, "invocation_id"))

    cond do
      service not in @services ->
        {:error, :invalid_service}

      is_integer(sampled) and sampled in 1..@max_counter and is_integer(started) and
        started in 1..@max_counter and valid_identity?(started, incarnation, invocation) ->
        :ok

      true ->
        {:error, :invalid_identity}
    end
  end

  @spec validate_counts(map()) :: :ok | {:error, validation_error()}
  defp validate_counts(snapshot) do
    values =
      for key <- [:requests, :successes, :failures],
          into: [],
          do: Map.get(snapshot, key, Map.get(snapshot, Atom.to_string(key)))

    case values do
      [requests, successes, failures]
      when is_integer(requests) and requests in 0..@max_counter and
             is_integer(successes) and successes in 0..@max_counter and
             is_integer(failures) and failures in 0..@max_counter and
             requests == successes + failures ->
        :ok

      _ ->
        {:error, :invalid_counts}
    end
  end

  @spec validate_duration(map()) :: :ok | {:error, validation_error()}
  defp validate_duration(snapshot) do
    duration = Map.get(snapshot, :duration, Map.get(snapshot, "duration"))

    requests = Map.get(snapshot, :requests, Map.get(snapshot, "requests"))

    with true <- is_map(duration),
         :ok <- validate_keys(duration, @duration_keys),
         true <- is_integer(requests) and requests >= 0 and requests <= @max_counter,
         count when is_integer(count) and count >= 0 <- value(duration, :count),
         true <- count <= requests,
         sum when is_integer(sum) and sum >= 0 <- value(duration, :sum_us),
         true <- sum <= @max_counter,
         bounds when is_list(bounds) <- value(duration, :explicit_bounds_us),
         buckets when is_list(buckets) <- value(duration, :bucket_counts),
         true <- bounds == @bounds_us,
         true <- length(buckets) == @bucket_count,
         true <- Enum.all?(buckets, &(is_integer(&1) and &1 in 0..@max_counter)),
         true <- count == Enum.sum(buckets) do
      _ = sum
      :ok
    else
      _ -> {:error, :invalid_duration}
    end
  end

  @spec value(map(), atom()) :: term()
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @spec valid_identity?(term(), term(), term()) :: boolean()
  defp valid_identity?(started, incarnation, invocation) do
    is_integer(started) and started in 1..@max_counter and valid_identifier?(incarnation) and
      valid_identifier?(invocation)
  end

  @spec valid_identifier?(term()) :: boolean()
  defp valid_identifier?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{32}\z/, value)

  @spec valid_options?(keyword()) :: boolean()
  defp valid_options?(opts) do
    Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @options)) and
      length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts)))
  end

  @spec validate_keys(map(), [binary()]) :: :ok | {:error, validation_error()}
  defp validate_keys(map, keys) do
    atom_keys = Enum.map(keys, &String.to_existing_atom/1)

    if Enum.sort(Map.keys(map)) in [Enum.sort(keys), Enum.sort(atom_keys)],
      do: :ok,
      else: {:error, :invalid_snapshot}
  rescue
    ArgumentError -> {:error, :invalid_snapshot}
  end

  @spec new_identity() :: binary()
  defp new_identity, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
