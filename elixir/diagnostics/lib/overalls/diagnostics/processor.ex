defmodule Overalls.Diagnostics.Processor do
  @moduledoc false
  use GenServer
  @behaviour :otel_span_processor
  @capacity 256
  @batch_size 128
  @queue __MODULE__.Queue
  @key {__MODULE__, :counters}
  @catalogs %{
    Marshall.Events => "marshall.observability_health",
    Lilly.Events => "lilly.observability_health",
    Audi.Events => "audi.observability_health",
    Brady.Events => "brady.observability_health",
    Porsche.Events => "porsche.observability_health",
    Ziggy.Events => "ziggy.observability_health",
    Enrico.Events => "enrico.observability_health",
    Galileo.Events => "galileo.observability_health",
    Susan.Events => "susan.observability_health",
    Peach.Events => "peach.observability_health"
  }
  @type state :: %{counters: :atomics.atomics_ref(), catalog: module() | nil}

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(_config), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  @spec init([]) :: {:ok, state()}
  def init([]) do
    _ = :ets.new(@queue, [:named_table, :public, :set, write_concurrency: true])
    counters = :atomics.new(2, signed: false)
    :persistent_term.put(@key, {self(), counters})
    Process.send_after(self(), :flush, 100)
    Process.send_after(self(), :report_health, 30_000)
    configured = Application.get_env(:overalls_diagnostics, :events_catalog)
    catalog = if Map.has_key?(@catalogs, configured), do: configured, else: nil
    {:ok, %{counters: counters, catalog: catalog}}
  end

  @impl true
  @spec on_start(:otel_ctx.t(), :opentelemetry.span(), map()) :: :opentelemetry.span()
  def on_start(_context, span, _config), do: span

  @impl true
  @spec on_end(:opentelemetry.span(), map()) :: true | :dropped
  def on_end(span, _config) do
    result = enqueue(span)

    if Process.get({Overalls.Diagnostics.Custody, :mode}) == :enqueue,
      do:
        Process.put(
          {Overalls.Diagnostics.Custody, :result},
          if(result == true, do: :ok, else: {:error, :refused})
        )

    result
  end

  # @cc [owner:ghuntley,label:capacity] processor-bounded-admission
  # The volatile routine queue MUST contain at most 256 spans. Atomic insertion
  # into fixed ETS slots MUST avoid leaked reservations on producer death. Queue
  # admission MUST NOT send unbounded messages or perform exporter I/O.
  @spec enqueue(:opentelemetry.span()) :: true | :dropped
  defp enqueue(span) do
    offset = rem(:erlang.unique_integer([:positive]), @capacity)

    accepted =
      Enum.any?(0..(@capacity - 1), &:ets.insert_new(@queue, {rem(offset + &1, @capacity), span}))

    if accepted do
      true
    else
      count(1, 1)
      :dropped
    end
  rescue
    ArgumentError -> :dropped
  end

  @impl true
  @spec handle_info(:flush | :report_health, state()) :: {:noreply, state()}
  def handle_info(:flush, state) do
    _ = flush_batch(state)
    Process.send_after(self(), :flush, 100)
    {:noreply, state}
  end

  def handle_info(:report_health, state) do
    :ok = publish_health(state.catalog)
    Process.send_after(self(), :report_health, 30_000)
    {:noreply, state}
  end

  # @cc [owner:ghuntley,label:security;capacity] producer-health-independent-logs
  # Health MUST use only the configured finite application catalog and bounded
  # numeric queue counters. Its log event MUST bypass trace admission so a full
  # or unavailable spool remains observable without recursive queue growth.
  @spec publish_health(module() | nil) :: :ok
  def publish_health(catalog) do
    with name when is_binary(name) <- Map.get(@catalogs, catalog),
         true <- Code.ensure_loaded?(catalog) do
      observed = health()

      metadata = [
        trace_available: if(observed.available, do: 1, else: 0),
        trace_pending: observed.pending,
        trace_queue_dropped: min(observed.queue_dropped, 9_007_199_254_740_991),
        trace_export_failed: min(observed.export_failed, 9_007_199_254_740_991)
      ]

      apply(catalog, :__emit__, [name, :info, "Observability producer health observed", metadata])
    end

    :ok
  catch
    _, _ -> :ok
  end

  @impl true
  @spec handle_call(:flush, GenServer.from(), state()) ::
          {:reply, :ok | {:error, :unavailable}, state()}
  def handle_call(:flush, _from, state) do
    result =
      Enum.reduce(1..2, :ok, fn _, prior ->
        case flush_batch(state) do
          :ok -> prior
          error -> error
        end
      end)

    {:reply, result, state}
  end

  @spec flush_batch(state()) :: :ok | {:error, :unavailable}
  defp flush_batch(state) do
    spans =
      @queue
      |> :ets.tab2list()
      |> Enum.take(@batch_size)
      |> Enum.flat_map(fn {key, _} ->
        case :ets.take(@queue, key) do
          [{_, span}] -> [span]
          [] -> []
        end
      end)

    case spans do
      [] ->
        :ok

      _ ->
        if Overalls.Diagnostics.Exporter.export(spans) == :ok do
          :ok
        else
          :atomics.add(state.counters, 2, length(spans))
          {:error, :unavailable}
        end
    end
  end

  @impl true
  @spec force_flush(map()) :: :ok | {:error, :unavailable}
  def force_flush(_config) do
    GenServer.call(__MODULE__, :flush, 1500)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec health() :: %{
          available: boolean(),
          pending: non_neg_integer(),
          queue_dropped: non_neg_integer(),
          export_failed: non_neg_integer()
        }
  def health do
    case :persistent_term.get(@key, nil) do
      {pid, counters} ->
        if Process.alive?(pid) and :ets.info(@queue) != :undefined do
          %{
            available: true,
            pending: :ets.info(@queue, :size),
            queue_dropped: :atomics.get(counters, 1),
            export_failed: :atomics.get(counters, 2)
          }
        else
          unavailable()
        end

      nil ->
        unavailable()
    end
  end

  @spec unavailable() :: %{available: false, pending: 0, queue_dropped: 0, export_failed: 0}
  defp unavailable, do: %{available: false, pending: 0, queue_dropped: 0, export_failed: 0}

  @spec count(1 | 2, non_neg_integer()) :: :ok
  defp count(index, amount) do
    case :persistent_term.get(@key, nil) do
      {_, counters} -> :atomics.add(counters, index, amount)
      nil -> :ok
    end
  end

  @impl true
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, _state) do
    :persistent_term.erase(@key)
    :ok
  end
end
