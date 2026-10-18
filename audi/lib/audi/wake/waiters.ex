defmodule Audi.Wake.Waiters do
  @moduledoc "A finite process-owned budget for sleeping connection admissions."
  use GenServer
  @maximum 128

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  @spec acquire() :: :ok | {:error, :capacity}
  def acquire, do: GenServer.call(__MODULE__, :acquire)
  @spec release() :: :ok
  def release, do: GenServer.call(__MODULE__, :release)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call(:acquire, {owner, _}, state) do
    cond do
      Map.has_key?(state, owner) -> {:reply, {:error, :capacity}, state}
      map_size(state) >= @maximum -> {:reply, {:error, :capacity}, state}
      true -> {:reply, :ok, Map.put(state, owner, Process.monitor(owner))}
    end
  end

  def handle_call(:release, {owner, _}, state) do
    {monitor, state} = Map.pop(state, owner)
    if monitor, do: Process.demonitor(monitor, [:flush])
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, reference, :process, owner, _}, state) do
    {:noreply, if(Map.get(state, owner) == reference, do: Map.delete(state, owner), else: state)}
  end
end
