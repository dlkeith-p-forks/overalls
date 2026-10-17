defmodule Overalls.Diagnostics.Metrics do
  @moduledoc "Supervised, finite runtime metric aggregation and typed Telemetry admission."
  use GenServer

  @max_value 9_223_372_036_854_775_807
  @table __MODULE__.Table
  @owner {__MODULE__, :owner}
  @registry %{
    [:phoenix, :endpoint, :stop] => %{measurements: [duration: :integer], metadata: []},
    [:audi, :ssh, :candidate] => %{measurements: [count: :integer], metadata: []},
    [:audi, :ssh, :proved] => %{measurements: [count: :integer], metadata: []},
    [:lilly, :control, :backoff] => %{measurements: [count: :integer], metadata: []},
    [:lilly, :control, :fenced] => %{measurements: [count: :integer], metadata: []},
    [:marshall, :control, :hint] => %{
      measurements: [count: :integer],
      metadata: [kind: :atom, id: :uuid]
    },
    [:marshall, :control, :request] => %{
      measurements: [duration: :integer],
      metadata: [status: :http_status]
    },
    [:marshall, :ssh, :request] => %{
      measurements: [duration: :integer],
      metadata: [status: :http_status]
    },
    [:marshall, :terminal, :authority] => %{
      measurements: [duration: :integer],
      metadata: [status: :http_status]
    },
    [:marshall, :terminal, :input] => %{measurements: [duration: :integer], metadata: []},
    [:marshall, :repo, :query] => %{
      measurements: [total_time: :integer, queue_time: :integer],
      metadata: []
    },
    [:oban, :job, :stop] => %{measurements: [duration: :integer], metadata: []},
    [:oban, :job, :exception] => %{measurements: [duration: :integer], metadata: []},
    [:porsche, :ssh, :candidate] => %{measurements: [count: :integer], metadata: []},
    [:porsche, :ssh, :proved] => %{measurements: [count: :integer], metadata: []},
    [:porsche, :http, :complete] => %{
      measurements: [duration_us: :integer, error: :binary_flag, eligible: :boolean],
      metadata: []
    },
    [:porsche, :ssh, :complete] => %{
      measurements: [duration_us: :integer, error: :binary_flag, eligible: :boolean],
      metadata: []
    }
  }
  @capacity Enum.reduce(@registry, 0, fn {_event, spec}, total ->
              total + length(spec.measurements)
            end)

  @type event :: [atom(), ...]
  @type measurements :: %{required(atom()) => non_neg_integer() | boolean()}
  @type metadata :: %{optional(atom()) => atom() | binary() | non_neg_integer()}
  @type aggregate :: non_neg_integer() | :unknown
  @type snapshot :: %{binary() => %{binary() => aggregate()}}
  @type snapshot_result :: {:ok, snapshot()} | {:error, :unavailable}
  @typep metric_spec :: %{
           measurements: keyword(:integer | :binary_flag | :boolean),
           metadata: keyword(atom())
         }
  @type result :: :ok | {:error, :invalid | :unavailable | :overflow}
  @type state :: %{counters: :atomics.atomics_ref()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  @spec init([]) :: {:ok, state()}
  def init([]) do
    _ =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ok = initialize()
    counters = :atomics.new(1, signed: true)
    :persistent_term.put(@owner, {self(), counters})
    {:ok, %{counters: counters}}
  end

  # @cc [owner:ghuntley,label:capacity;security] shared-metric-closed-registry
  # Metric producers MUST use the finite registry and bounded nonnegative
  # measurements. Unknown paths, measurement keys and labels MUST be rejected
  # before Telemetry emission. Aggregates MUST NOT retain metadata or grow keys.
  @doc "Record a reviewed measurement and emit validated Telemetry data."
  @spec record(event(), map(), map() | keyword()) :: result()
  def record(event, measurements, metadata \\ %{}) do
    with {:ok, event, spec} <- validate_event(event),
         {:ok, measurements} <- validate_measurements(measurements, spec),
         {:ok, metadata} <- validate_metadata(metadata, spec) do
      result =
        if available?() do
          Enum.reduce(measurements, :ok, fn {name, value}, prior ->
            case update(key(event, name), numeric(value)) do
              :ok -> prior
              error -> error
            end
          end)
        else
          {:error, :unavailable}
        end

      :ok = emit(event, measurements, metadata)
      result
    end
  end

  # @cc [owner:ghuntley,label:verification] shared-metric-snapshot-availability
  # Snapshot reads MUST distinguish an available empty registry from an
  # unavailable registry, including when its owner disappears during the read.
  @doc "Read the current aggregate values without consuming them."
  @spec snapshot() :: snapshot_result()
  def snapshot, do: read_snapshot(&snapshot_values/1)

  # @cc [owner:ghuntley,label:capacity] shared-metric-interval-consumption
  # Each accepted increment MUST be consumed exactly once across interval reads
  # until explicit reset. Consumption is atomic per measurement, not across the
  # registry, and MUST preserve :unknown aggregates until explicit reset.
  @doc """
  Consume the current interval values, atomically per registered measurement.

  An overflowed measurement remains `:unknown` in every snapshot until `reset/0`.
  Measurements can be observed at different instants within one snapshot.
  """
  @spec take_snapshot() :: snapshot_result()
  def take_snapshot, do: read_snapshot(&interval_snapshot/1)

  @spec snapshot_values(:ets.tid()) :: snapshot()
  defp snapshot_values(table) do
    table
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn
      {{_event, _metric}, 0}, acc ->
        acc

      {key, value}, acc ->
        put_snapshot(acc, key, value)
    end)
  end

  @spec read_snapshot((:ets.tid() -> snapshot())) :: snapshot_result()
  defp read_snapshot(fun) do
    with {:ok, table} <- current_table() do
      {:ok, fun.(table)}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @spec interval_snapshot(:ets.tid()) :: snapshot()
  defp interval_snapshot(table) do
    table
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn {key, _value}, acc ->
      case take_for_interval(table, key) do
        0 -> acc
        value -> put_snapshot(acc, key, value)
      end
    end)
  end

  @spec put_snapshot(%{binary() => %{binary() => aggregate()}}, {binary(), binary()}, aggregate()) ::
          %{binary() => %{binary() => aggregate()}}
  defp put_snapshot(acc, {event, metric}, value),
    do: Map.update(acc, event, %{metric => value}, &Map.put(&1, metric, value))

  # Compare-and-replace makes interval consumption atomic for each fixed key:
  # increments that race the read either happen before the replacement and are
  # included, or happen after it and remain in the table for the next interval.
  @spec take_for_interval(:ets.tid(), {binary(), binary()}) :: aggregate()
  defp take_for_interval(table, key) do
    case :ets.lookup(table, key) do
      [{^key, :unknown}] ->
        :unknown

      [{^key, current}] ->
        match = [{{key, current}, [], [{:const, {key, 0}}]}]

        case :ets.select_replace(table, match) do
          1 -> current
          0 -> take_for_interval(table, key)
        end

      [] ->
        raise ArgumentError, "metric registry is unavailable"
    end
  end

  @spec reset() :: :ok | {:error, :unavailable}
  def reset do
    GenServer.call(__MODULE__, :reset)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  @spec handle_call(:reset, GenServer.from(), state()) :: {:reply, :ok, state()}
  def handle_call(:reset, _from, state) do
    :ok = initialize()
    :atomics.put(state.counters, 1, 0)
    {:reply, :ok, state}
  end

  @spec health() :: %{
          available: boolean(),
          size: non_neg_integer(),
          capacity: pos_integer(),
          dropped: non_neg_integer()
        }
  def health do
    case :persistent_term.get(@owner, nil) do
      {pid, counters} when is_pid(pid) ->
        if Process.alive?(pid) do
          %{
            available: true,
            size: :ets.info(@table, :size),
            capacity: @capacity,
            dropped: :atomics.get(counters, 1)
          }
        else
          unavailable()
        end

      _ ->
        unavailable()
    end
  rescue
    ArgumentError -> unavailable()
  end

  @spec validate_event(term()) :: {:ok, event(), metric_spec()} | {:error, :invalid}
  defp validate_event(event) do
    case Map.fetch(@registry, event) do
      {:ok, spec} -> {:ok, event, spec}
      :error -> {:error, :invalid}
    end
  end

  @spec validate_measurements(term(), metric_spec()) :: {:ok, measurements()} | {:error, :invalid}
  defp validate_measurements(values, spec) when is_map(values) and map_size(values) > 0 do
    required = Keyword.keys(spec.measurements)

    if MapSet.new(Map.keys(values)) == MapSet.new(required) and
         Enum.all?(values, fn {key, value} ->
           measurement_shape?(Keyword.fetch!(spec.measurements, key), value)
         end),
       do: {:ok, values},
       else: {:error, :invalid}
  end

  defp validate_measurements(_, _), do: {:error, :invalid}

  @spec validate_metadata(term(), metric_spec()) :: {:ok, metadata()} | {:error, :invalid}
  defp validate_metadata(values, spec) when is_list(values) do
    if Keyword.keyword?(values) and length(values) == length(Enum.uniq(Keyword.keys(values))),
      do: validate_metadata(Map.new(values), spec),
      else: {:error, :invalid}
  end

  defp validate_metadata(values, spec) when is_map(values) do
    if Enum.all?(values, fn {name, value} -> shape?(Keyword.get(spec.metadata, name), value) end),
      do: {:ok, values},
      else: {:error, :invalid}
  end

  defp validate_metadata(_, _), do: {:error, :invalid}

  # @cc [owner:ghuntley,label:capacity] shared-metric-overflow-unknown
  # A sum above the declared int64 maximum MUST become :unknown and remain
  # unknown until reset; concurrency MUST NOT lose accepted increments or turn
  # overflow into a plausible saturated value.
  @spec update({binary(), binary()}, non_neg_integer()) ::
          :ok | {:error, :unavailable | :overflow}
  defp update(key, amount) do
    case :ets.lookup(@table, key) do
      [{^key, :unknown}] ->
        {:error, :overflow}

      [{^key, prior}] ->
        next = if prior + amount <= @max_value, do: prior + amount, else: :unknown
        match = [{{key, prior}, [], [{:const, {key, next}}]}]

        case :ets.select_replace(@table, match) do
          1 when next == :unknown ->
            count_overflow()
            {:error, :overflow}

          1 ->
            :ok

          0 ->
            update(key, amount)
        end

      [] ->
        {:error, :unavailable}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @spec initialize() :: :ok
  defp initialize do
    for {event, spec} <- @registry,
        {name, _type} <- spec.measurements,
        do: :ets.insert(@table, {key(event, name), 0})

    :ok
  end

  @spec key(event(), atom()) :: {binary(), binary()}
  defp key(event, name), do: {Enum.map_join(event, ".", &Atom.to_string/1), Atom.to_string(name)}

  @spec integer?(term()) :: boolean()
  defp integer?(value), do: is_integer(value) and value in 0..@max_value

  @spec measurement_shape?(atom(), term()) :: boolean()
  defp measurement_shape?(:integer, value), do: integer?(value)
  defp measurement_shape?(:binary_flag, value), do: value in [0, 1]
  defp measurement_shape?(:boolean, value), do: is_boolean(value)

  @spec numeric(non_neg_integer() | boolean()) :: non_neg_integer()
  defp numeric(true), do: 1
  defp numeric(false), do: 0
  defp numeric(value), do: value

  @spec shape?(atom() | nil, term()) :: boolean()
  defp shape?(:uuid, value), do: Overalls.Diagnostics.Schema.uuid?(value)

  defp shape?(:atom, value),
    do: is_atom(value) and value != nil and Overalls.Diagnostics.Schema.enum?(value)

  defp shape?(:http_status, value), do: is_integer(value) and value in 100..599
  defp shape?(_, _), do: false

  @spec available?() :: boolean()
  defp available?, do: health().available

  @spec current_table() :: {:ok, :ets.tid()} | {:error, :unavailable}
  defp current_table do
    with {pid, _counters} when is_pid(pid) <- :persistent_term.get(@owner, nil),
         true <- Process.alive?(pid),
         table when table != :undefined <- :ets.whereis(@table),
         ^pid <- :ets.info(table, :owner) do
      {:ok, table}
    else
      _ -> {:error, :unavailable}
    end
  end

  @spec unavailable() :: %{available: false, size: 0, capacity: pos_integer(), dropped: 0}
  defp unavailable, do: %{available: false, size: 0, capacity: @capacity, dropped: 0}

  @spec count_overflow() :: :ok
  defp count_overflow do
    case :persistent_term.get(@owner, nil) do
      {_pid, counters} -> :atomics.add(counters, 1, 1)
      nil -> :ok
    end

    :ok
  end

  @spec emit(event(), measurements(), metadata()) :: :ok
  defp emit(event, values, metadata) do
    :telemetry.execute(event, values, metadata)
    :ok
  catch
    _, _ -> :ok
  end

  @impl true
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, _state) do
    :persistent_term.erase(@owner)
    :ok
  end
end
