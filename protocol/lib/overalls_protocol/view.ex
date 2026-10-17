defmodule OverallsProtocol.View do
  @moduledoc """
  A versioned, single-writer, in-memory read model.

  The view process owns protected ETS tables. Each key is claimed by exactly one
  writer process; only that writer may put or delete the key's row, and the row
  disappears when the writer exits. Readers use `fetch/2` and `lookup/2`, which
  read ETS directly and never call or block the view process or any writer.
  Every write receives a strictly larger version, so a reader can detect a
  change between two reads.

  Rows are volatile: when the view process restarts, its tables are recreated
  empty, so consumers fail closed until writers republish.
  """
  use GenServer

  @type view :: atom()
  @type key :: term()
  @type version :: pos_integer()
  @type row :: {version(), term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    name = Keyword.fetch!(options, :name)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: {__MODULE__, Keyword.fetch!(options, :name)},
      start: {__MODULE__, :start_link, [options]}
    }
  end

  # @cc [owner:ghuntley,label:security;architecture] view-single-writer
  # Only the process that claimed a key may write or delete its row; a second
  # claimant MUST be refused while the first is alive. A claimant's rows and
  # index entries MUST be removed when it exits, and a restarted view MUST start
  # empty. Every put MUST be assigned a version greater than any earlier one.
  @doc "Claims `key` for the calling process. Idempotent for the current owner."
  @spec claim(view(), key()) :: :ok | {:error, :claimed}
  def claim(view, key), do: GenServer.call(view, {:claim, key})

  @doc "Publishes the caller's row for `key` with lookup terms; returns its version."
  @spec put(view(), key(), term(), [term()]) :: {:ok, version()} | {:error, :not_owner}
  def put(view, key, value, terms \\ []) when is_list(terms),
    do: GenServer.call(view, {:put, key, value, Enum.uniq(terms)})

  @doc "Removes the caller's row for `key`, keeping the claim."
  @spec delete(view(), key()) :: :ok | {:error, :not_owner}
  def delete(view, key), do: GenServer.call(view, {:delete, key})

  @doc "Removes the row and gives up the claim."
  @spec release(view(), key()) :: :ok | {:error, :not_owner}
  def release(view, key), do: GenServer.call(view, {:release, key})

  # @cc [owner:ghuntley,label:security;recovery] view-change-notification
  # A subscriber MUST receive {:view_changed, view, key} after every put or
  # delete of a subscribed key, including removals caused by its writer's exit,
  # so revocation can be event-driven. Notifications carry no row data; the
  # subscriber re-reads. A subscription ends when the subscriber exits.
  @doc "Subscribes the caller to change notifications for `keys`."
  @spec subscribe(view(), [key()]) :: :ok
  def subscribe(view, keys) when is_list(keys), do: GenServer.call(view, {:subscribe, keys})

  # @cc [owner:ghuntley,label:capacity;security] view-lock-free-exact-read
  # fetch/2 and lookup/2 MUST read ETS without messaging the view or a writer,
  # and MUST return only rows present at read time. lookup/2 MUST NOT return a
  # row whose current terms no longer include the requested term.
  @doc "The current row for `key`."
  @spec fetch(view(), key()) :: {:ok, row()} | :error
  def fetch(view, key) do
    case :ets.lookup(view, key) do
      [{^key, version, value, _terms}] -> {:ok, {version, value}}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Rows currently published under lookup `term`, as `{key, version, value}`."
  @spec lookup(view(), term()) :: [{key(), version(), term()}]
  def lookup(view, term) do
    for {^term, key} <- :ets.lookup(index(view), term),
        [{^key, version, value, terms}] <- [:ets.lookup(view, key)],
        term in terms,
        do: {key, version, value}
  rescue
    ArgumentError -> []
  end

  @impl true
  def init(name) do
    :ets.new(name, [:set, :protected, :named_table, read_concurrency: true])
    :ets.new(index(name), [:bag, :protected, :named_table, read_concurrency: true])

    {:ok,
     %{name: name, version: 0, owners: %{}, monitors: %{}, subscribers: %{}, subscriptions: %{}}}
  end

  @impl true
  def handle_call({:subscribe, keys}, {pid, _}, state) do
    subscriptions =
      Map.put_new_lazy(state.subscriptions, pid, fn -> Process.monitor(pid) end)

    subscribers =
      Enum.reduce(keys, state.subscribers, fn key, acc ->
        Map.update(acc, key, MapSet.new([pid]), &MapSet.put(&1, pid))
      end)

    {:reply, :ok, %{state | subscribers: subscribers, subscriptions: subscriptions}}
  end

  def handle_call({:claim, key}, {pid, _}, state) do
    case Map.fetch(state.owners, key) do
      {:ok, {^pid, _ref}} ->
        {:reply, :ok, state}

      {:ok, _other} ->
        {:reply, {:error, :claimed}, state}

      :error ->
        ref = Process.monitor(pid)

        {:reply, :ok,
         %{
           state
           | owners: Map.put(state.owners, key, {pid, ref}),
             monitors: Map.update(state.monitors, ref, [key], &[key | &1])
         }}
    end
  end

  def handle_call({:put, key, value, terms}, {pid, _}, state) do
    with {:ok, {^pid, _ref}} <- Map.fetch(state.owners, key) do
      version = state.version + 1

      previous =
        case :ets.lookup(state.name, key) do
          [{^key, _version, _value, terms}] -> terms
          [] -> []
        end

      # New index entries, then the atomic row replacement, then stale entries:
      # a concurrent reader never misses a row that stays published.
      Enum.each(terms, &:ets.insert(index(state.name), {&1, key}))
      :ets.insert(state.name, {key, version, value, terms})
      Enum.each(previous -- terms, &:ets.delete_object(index(state.name), {&1, key}))
      notify(state, key)
      {:reply, {:ok, version}, %{state | version: version}}
    else
      _ -> {:reply, {:error, :not_owner}, state}
    end
  end

  def handle_call({:delete, key}, {pid, _}, state) do
    case Map.fetch(state.owners, key) do
      {:ok, {^pid, _ref}} ->
        remove(state.name, key)
        notify(state, key)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  def handle_call({:release, key}, {pid, _}, state) do
    case Map.fetch(state.owners, key) do
      {:ok, {^pid, ref}} ->
        remove(state.name, key)
        notify(state, key)
        {:reply, :ok, drop(state, key, ref)}

      _ ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    keys = Map.get(state.monitors, ref, [])
    Enum.each(keys, &remove(state.name, &1))
    state = unsubscribe(state, pid, ref)
    Enum.each(keys, &notify(state, &1))

    {:noreply,
     %{state | owners: Map.drop(state.owners, keys), monitors: Map.delete(state.monitors, ref)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp notify(state, key) do
    for pid <- Map.get(state.subscribers, key, MapSet.new()),
        do: send(pid, {:view_changed, state.name, key})

    :ok
  end

  defp unsubscribe(state, pid, ref) do
    case Map.fetch(state.subscriptions, pid) do
      {:ok, ^ref} ->
        subscribers =
          state.subscribers
          |> Map.new(fn {key, pids} -> {key, MapSet.delete(pids, pid)} end)
          |> Map.reject(fn {_key, pids} -> MapSet.size(pids) == 0 end)

        %{state | subscribers: subscribers, subscriptions: Map.delete(state.subscriptions, pid)}

      _ ->
        state
    end
  end

  defp drop(state, key, ref) do
    keys = Map.get(state.monitors, ref, []) -- [key]

    monitors =
      if keys == [] do
        Process.demonitor(ref, [:flush])
        Map.delete(state.monitors, ref)
      else
        Map.put(state.monitors, ref, keys)
      end

    %{state | owners: Map.delete(state.owners, key), monitors: monitors}
  end

  # Row first: a reader that still finds the index entry then misses the row.
  defp remove(name, key) do
    :ets.delete(name, key)
    unindex(name, key)
  end

  defp unindex(name, key), do: :ets.match_delete(index(name), {:_, key})

  defp index(name), do: :"#{name}.index"
end
