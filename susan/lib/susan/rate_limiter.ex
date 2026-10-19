defmodule Susan.RateLimiter do
  @moduledoc """
  Serialised token buckets per push key, install identity, source address
  digest and globally (ADR-0224).

  A check admits a request only if every named bucket has a token; a refusal
  consumes nothing from the other buckets. Bucket keys are opaque digests or
  key ids, never addresses or tokens. State is node-local memory and is lost
  on restart, which only ever resets buckets to full.
  """
  use GenServer

  alias Susan.TokenBucket

  @type scope :: :key | :install | :source | :global | :issue
  @type limits :: %{scope() => TokenBucket.limit()}
  @type bucket :: {scope(), term()}
  @type outcome :: :ok | {:limited, scope(), pos_integer(), boolean()}

  @defaults %{
    key: %{burst: 10, per_hour: 60},
    install: %{burst: 120, per_hour: 3_600},
    source: %{burst: 120, per_hour: 3_600},
    global: %{burst: 2_000, per_hour: 360_000},
    issue: %{burst: 10, per_hour: 60}
  }

  @spec defaults() :: limits()
  def defaults, do: @defaults

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(options, :name, __MODULE__))
  end

  # @cc [owner:ghuntley,label:capacity;security] susan-rate-check-all-or-nothing
  # A request MUST be admitted only when every one of its buckets admits it.
  # A refused request MUST NOT consume tokens from any bucket, and the refusal
  # MUST name the limiting scope and a positive Retry-After.
  @spec check([bucket()], limits(), integer(), GenServer.server()) :: outcome()
  def check(buckets, limits, now_ms \\ System.monotonic_time(:millisecond), server \\ __MODULE__)
      when is_list(buckets) and is_map(limits) and is_integer(now_ms),
      do: GenServer.call(server, {:check, buckets, Map.merge(@defaults, limits), now_ms})

  @impl true
  def init(_options) do
    Process.send_after(self(), :sweep, 600_000)
    {:ok, %{limits: %{}, buckets: %{}}}
  end

  @impl true
  def handle_call({:check, requested, limits, now}, _from, state) do
    state = %{
      state
      | limits:
          Map.merge(
            state.limits,
            Map.new(requested, fn {scope, _} = name -> {name, Map.fetch!(limits, scope)} end)
          )
    }

    results =
      Enum.map(requested, fn name ->
        {name,
         TokenBucket.take(Map.get(state.buckets, name), Map.fetch!(state.limits, name), now)}
      end)

    case Enum.filter(results, &match?({_, {:error, _, _, _}}, &1)) do
      [] ->
        buckets =
          Enum.reduce(results, state.buckets, fn {name, {:ok, b}}, acc ->
            Map.put(acc, name, b)
          end)

        {:reply, :ok, %{state | buckets: buckets}}

      refused ->
        buckets =
          Enum.reduce(refused, state.buckets, fn {name, {:error, _, _, b}}, acc ->
            Map.put(acc, name, b)
          end)

        {{scope, _}, {:error, retry, first, _}} =
          Enum.max_by(refused, fn {_, {:error, r, _, _}} -> r end)

        {:reply, {:limited, scope, retry, first}, %{state | buckets: buckets}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    buckets =
      Map.reject(state.buckets, fn {name, bucket} ->
        TokenBucket.full?(bucket, Map.fetch!(state.limits, name), now)
      end)

    Process.send_after(self(), :sweep, 600_000)
    {:noreply, %{state | buckets: buckets, limits: Map.take(state.limits, Map.keys(buckets))}}
  end
end
