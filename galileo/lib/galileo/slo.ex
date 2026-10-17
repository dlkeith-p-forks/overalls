defmodule Galileo.SLO do
  @moduledoc "Source-owned cumulative outcomes for admitted integration attempts."
  use GenServer
  alias Overalls.RequestAccounting.Aggregate

  @type state :: Aggregate.t()
  @type snapshot :: Aggregate.snapshot()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # @cc [owner:ghuntley,label:reliability;security] galileo-admitted-outcome-once
  # Each authorized attempt MUST add exactly one terminal outcome and one duration
  # observation. Caller-controlled identity, path and content MUST NOT become labels.
  @spec record(boolean(), non_neg_integer()) :: :ok
  def record(success, duration_us)
      when is_boolean(success) and is_integer(duration_us) and duration_us >= 0 do
    GenServer.cast(__MODULE__, {:record, success, duration_us})
  end

  @spec snapshot() :: snapshot()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    {:ok, Aggregate.new("galileo")}
  end

  @impl true
  @spec handle_cast({:record, boolean(), non_neg_integer()}, state()) :: {:noreply, state()}
  def handle_cast({:record, success, duration_us}, state) do
    {:noreply, Aggregate.record(state, if(success, do: :success, else: :failure), duration_us)}
  end

  @impl true
  @spec handle_call(:snapshot, GenServer.from(), state()) :: {:reply, snapshot(), state()}
  def handle_call(:snapshot, _from, state) do
    {:reply, Aggregate.snapshot(state), state}
  end
end
