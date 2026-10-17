defmodule Lilly.Host.PoolQueue do
  @moduledoc """
  Fair turns for each pool lock (ADR-0176 decision 1, first stage).

  Callers wait in FIFO order within three priority classes (observations,
  then mutations, then upkeep) and are woken by a message when their turn
  comes, instead of polling the native lock. A turn grants nothing by itself:
  the turn holder still acquires the pool `flock` through the native helper,
  so crash custody and the lock inode are unchanged. A crashed queue loses
  only ordering; the `flock` still excludes.
  """
  use GenServer

  @typedoc "Observations (capacity snapshots) first, then mutations, then upkeep."
  @type priority :: :observe | :mutate | :upkeep
  @priorities [:observe, :mutate, :upkeep]
  @max_wait_ms 30_000

  @typedoc "Work a turn holder may run on a waiter's behalf: a key and the waiter's item."
  @type combinable :: {atom(), term()} | nil
  @type entry :: %{
          ref: reference(),
          from: GenServer.from(),
          pid: pid(),
          timer: reference() | nil,
          combine: combinable()
        }
  @type lane :: %{
          holder: {reference(), pid(), reference()} | nil,
          queues: %{priority() => :queue.queue(entry())}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(options, :name, __MODULE__))

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}

  # @cc [owner:ghuntley,label:concurrency;capacity] pool-turns-fifo-per-priority
  # enter/3 MUST grant at most one turn per lock directory at a time, in FIFO
  # order within a priority, always preferring a waiting :observe entry over
  # :mutate and :mutate over :upkeep. A free lane with no waiters grants at once.
  # A zero wait never queues. A waiter whose wait expires, whose caller exits,
  # or that is cancelled MUST leave the queue without ever being granted, and a
  # holder that exits or leaves MUST pass the turn to the next waiter.
  # A BEAM that runs no queue (operator eval tools, machine-test probes)
  # receives `:unqueued` and contends only on the native lock.
  # A waiter that offers combinable work MAY instead be answered with
  # `{:combined, result}` by the turn holder that took its item (take/3).
  @spec enter(Path.t(), priority(), 0..30_000, combinable()) ::
          {:ok, reference() | :unqueued} | {:combined, term()} | {:error, :busy}
  def enter(directory, priority, wait_ms, combine \\ nil)
      when priority in @priorities and wait_ms in 0..@max_wait_ms do
    if Process.whereis(__MODULE__) do
      ref = make_ref()

      try do
        GenServer.call(
          __MODULE__,
          {:enter, directory, priority, ref, wait_ms, combine},
          wait_ms + 5_000
        )
      catch
        :exit, _ ->
          cancel(directory, ref)
          {:error, :busy}
      end
    else
      {:ok, :unqueued}
    end
  end

  @doc "Release a held turn; the next waiter is woken."
  @spec leave(Path.t(), reference() | :unqueued) :: :ok
  def leave(_directory, :unqueued), do: :ok
  def leave(directory, ref), do: cancel(directory, ref)

  # @cc [owner:ghuntley,label:concurrency;recovery] pool-turn-combining
  # take/3 MUST be called only by the current turn holder of the directory. It
  # removes and returns, in FIFO order, at most `max` waiters that offered work
  # under the same key; each is then never granted a turn and MUST receive
  # exactly one reply from the holder via answer/2. A taken waiter whose
  # holder dies receives no reply and fails by its own call timeout, never by
  # a later grant.
  @spec take(Path.t(), atom(), pos_integer()) :: [{GenServer.from(), term()}]
  def take(directory, key, max) when is_atom(key) and is_integer(max) and max > 0 do
    GenServer.call(__MODULE__, {:take, directory, key, max, self()})
  catch
    :exit, _ -> []
  end

  @doc "Answer a waiter whose work the turn holder ran."
  @spec answer(GenServer.from(), term()) :: :ok
  def answer(from, result), do: GenServer.reply(from, {:combined, result})

  @doc "Whether any caller is waiting for this lock directory (advisory, for yielding upkeep)."
  @spec waiting?(Path.t()) :: boolean()
  def waiting?(directory) do
    GenServer.call(__MODULE__, {:waiting?, directory})
  catch
    :exit, _ -> false
  end

  defp cancel(directory, ref) do
    GenServer.cast(__MODULE__, {:cancel, directory, ref})
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(:ok), do: {:ok, %{lanes: %{}, monitors: %{}}}

  @impl true
  def handle_call({:enter, directory, priority, ref, wait_ms, combine}, {pid, _} = from, state) do
    lane = lane(state, directory)

    cond do
      is_nil(lane.holder) and empty?(lane) ->
        {:reply, {:ok, ref}, hold(state, directory, lane, ref, pid)}

      wait_ms == 0 ->
        {:reply, {:error, :busy}, state}

      true ->
        timer = Process.send_after(self(), {:expire, directory, ref}, wait_ms)
        monitor = Process.monitor(pid)
        entry = %{ref: ref, from: from, pid: pid, timer: timer, combine: combine}
        lane = %{lane | queues: Map.update!(lane.queues, priority, &:queue.in(entry, &1))}

        {:noreply,
         %{
           state
           | lanes: Map.put(state.lanes, directory, lane),
             monitors: Map.put(state.monitors, monitor, {directory, ref})
         }}
    end
  end

  def handle_call({:take, directory, key, max, holder}, _from, state) do
    lane = lane(state, directory)

    case lane.holder do
      {_ref, ^holder, _monitor} ->
        {taken, queues} =
          Enum.reduce(@priorities, {[], lane.queues}, fn priority, {taken, queues} ->
            {matching, rest} =
              Enum.split_with(:queue.to_list(queues[priority]), &match?({^key, _}, &1.combine))

            {room, left} = Enum.split(matching, max(max - length(taken), 0))
            kept = :queue.from_list(Enum.sort_by(rest ++ left, &order(&1, queues[priority])))
            {taken ++ room, Map.put(queues, priority, kept)}
          end)

        state =
          Enum.reduce(
            taken,
            %{state | lanes: Map.put(state.lanes, directory, %{lane | queues: queues})},
            fn
              entry, state ->
                if entry.timer, do: Process.cancel_timer(entry.timer)
                forget(state, entry.ref)
            end
          )

        {:reply, Enum.map(taken, fn %{from: from, combine: {_key, item}} -> {from, item} end),
         state}

      _ ->
        {:reply, [], state}
    end
  end

  def handle_call({:waiting?, directory}, _from, state),
    do: {:reply, not empty?(lane(state, directory)), state}

  @impl true
  def handle_cast({:cancel, directory, ref}, state), do: {:noreply, drop(state, directory, ref)}

  @impl true
  def handle_info({:expire, directory, ref}, state) do
    case take_waiter(lane(state, directory), ref) do
      {nil, _lane} ->
        {:noreply, state}

      {entry, lane} ->
        GenServer.reply(entry.from, {:error, :busy})
        {:noreply, forget(%{state | lanes: Map.put(state.lanes, directory, lane)}, entry.ref)}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _} ->
        {:noreply, state}

      {{directory, ref}, monitors} ->
        {:noreply, drop(%{state | monitors: monitors}, directory, ref)}
    end
  end

  # Remove a waiter, or release the holder and grant the next waiter.
  defp drop(state, directory, ref) do
    lane = lane(state, directory)

    case lane.holder do
      {^ref, _pid, monitor} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | monitors: Map.delete(state.monitors, monitor)}
        grant_next(state, directory, %{lane | holder: nil})

      _ ->
        case take_waiter(lane, ref) do
          {nil, _} ->
            state

          {entry, lane} ->
            if entry.timer, do: Process.cancel_timer(entry.timer)
            forget(%{state | lanes: Map.put(state.lanes, directory, lane)}, entry.ref)
        end
    end
  end

  defp grant_next(state, directory, lane) do
    case next(lane) do
      nil ->
        %{state | lanes: Map.delete(state.lanes, directory)}

      {entry, lane} ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        state = forget(state, entry.ref)
        GenServer.reply(entry.from, {:ok, entry.ref})
        hold(state, directory, lane, entry.ref, entry.pid)
    end
  end

  defp hold(state, directory, lane, ref, pid) do
    monitor = Process.monitor(pid)

    %{
      state
      | lanes: Map.put(state.lanes, directory, %{lane | holder: {ref, pid, monitor}}),
        monitors: Map.put(state.monitors, monitor, {directory, ref})
    }
  end

  # Drop the waiter's monitor; the entry itself was already removed.
  defp forget(state, ref) do
    case Enum.find(state.monitors, fn {_monitor, {_dir, r}} -> r == ref end) do
      {monitor, _} ->
        Process.demonitor(monitor, [:flush])
        %{state | monitors: Map.delete(state.monitors, monitor)}

      nil ->
        state
    end
  end

  defp next(lane) do
    Enum.find_value(@priorities, fn priority ->
      case :queue.out(lane.queues[priority]) do
        {{:value, entry}, rest} -> {entry, %{lane | queues: Map.put(lane.queues, priority, rest)}}
        {:empty, _} -> nil
      end
    end)
  end

  defp take_waiter(lane, ref) do
    Enum.reduce_while(@priorities, {nil, lane}, fn priority, acc ->
      queue = lane.queues[priority]

      case Enum.split_with(:queue.to_list(queue), &(&1.ref == ref)) do
        {[entry], rest} ->
          {:halt,
           {entry, %{lane | queues: Map.put(lane.queues, priority, :queue.from_list(rest))}}}

        _ ->
          {:cont, acc}
      end
    end)
  end

  # Original FIFO position of an entry within its queue.
  defp order(entry, queue), do: Enum.find_index(:queue.to_list(queue), &(&1.ref == entry.ref))

  defp empty?(lane), do: Enum.all?(@priorities, &:queue.is_empty(lane.queues[&1]))

  defp lane(state, directory),
    do:
      Map.get(state.lanes, directory, %{
        holder: nil,
        queues: Map.new(@priorities, &{&1, :queue.new()})
      })
end
