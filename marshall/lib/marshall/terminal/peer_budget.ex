defmodule Marshall.Terminal.PeerBudget do
  @moduledoc "Process-owned admission slots shared by incoming and outgoing terminal peers."
  use GenServer

  @type state :: %{
          limit: pos_integer(),
          owners: %{pid() => reference()},
          monitors: %{reference() => pid()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    limit = Keyword.get(options, :limit, 512)

    if is_integer(limit) and limit > 0 do
      GenServer.start_link(
        __MODULE__,
        limit,
        Keyword.take(options, [:name]) |> Keyword.put_new(:name, __MODULE__)
      )
    else
      {:error, :invalid_limit}
    end
  end

  # @cc [owner:ghuntley,label:capacity;recovery] terminal-peer-process-budget
  # Incoming and outgoing peer connections MUST share a finite local budget.
  # Admission MUST precede outgoing TLS dial or incoming forwarding. Slots belong
  # to the calling process and MUST be released on death; owners MUST monitor the
  # returned budget process and stop if its accounting incarnation is lost.
  @spec acquire(GenServer.server()) :: {:ok, pid()} | {:error, :peer_capacity}
  def acquire(server \\ __MODULE__), do: GenServer.call(server, :acquire)

  @spec release(GenServer.server()) :: :ok
  def release(server \\ __MODULE__), do: GenServer.cast(server, {:release, self()})

  @spec used(GenServer.server()) :: non_neg_integer()
  def used(server \\ __MODULE__), do: GenServer.call(server, :used)

  @impl true
  @spec init(pos_integer()) :: {:ok, state()}
  def init(limit), do: {:ok, %{limit: limit, owners: %{}, monitors: %{}}}

  @impl true
  def handle_call(:acquire, {owner, _}, state) do
    cond do
      Map.has_key?(state.owners, owner) ->
        {:reply, {:ok, self()}, state}

      map_size(state.owners) >= state.limit ->
        {:reply, {:error, :peer_capacity}, state}

      true ->
        monitor = Process.monitor(owner)

        {:reply, {:ok, self()},
         %{
           state
           | owners: Map.put(state.owners, owner, monitor),
             monitors: Map.put(state.monitors, monitor, owner)
         }}
    end
  end

  def handle_call(:used, _, state), do: {:reply, map_size(state.owners), state}

  @impl true
  def handle_cast({:release, owner}, state), do: {:noreply, release_owner(state, owner)}

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _}, state) do
    if state.monitors[monitor] == owner,
      do: {:noreply, release_owner(state, owner)},
      else: {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @spec release_owner(state(), pid()) :: state()
  defp release_owner(state, owner) do
    case Map.pop(state.owners, owner) do
      {nil, _} ->
        state

      {monitor, owners} ->
        Process.demonitor(monitor, [:flush])
        %{state | owners: owners, monitors: Map.delete(state.monitors, monitor)}
    end
  end
end
