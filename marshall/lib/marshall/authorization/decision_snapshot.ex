defmodule Marshall.Authorization.DecisionSnapshot do
  @moduledoc """
  Read-only decision batches over one PostgreSQL snapshot.

  Inside `transaction/1` every statement sees the same repeatable-read snapshot,
  so a read repeated within the batch can only return the row it returned the
  first time. `fetch/2` memoizes such reads for the rest of the batch; outside a
  batch it always runs the read. Nothing survives the transaction or crosses
  processes, so the next batch observes revocations, retirements and demotions.
  """
  alias Marshall.Compute.Ledger
  alias Marshall.Repo

  @key {__MODULE__, :memo}

  # @cc [owner:ghuntley,label:security;concurrency] decision-snapshot-scope
  # Memoized reads MUST be confined to one outermost read-only repeatable-read
  # transaction owned by this process and MUST be discarded when it ends, raises
  # or rolls back. Nested in another transaction, the batch MUST NOT memoize and
  # every read MUST run fresh. Memoization MUST NOT change any decision the same
  # reads would produce at the batch's first statement.
  @spec transaction((-> term())) :: {:ok, term()} | {:error, term()}
  def transaction(fun) when is_function(fun, 0) do
    if Repo.in_transaction?() or active?() do
      Ledger.transaction(fun)
    else
      Ledger.transaction(fn ->
        if Application.get_env(:marshall, :decision_snapshot_isolation, true) do
          Ecto.Adapters.SQL.query!(
            Repo,
            "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY",
            [],
            log: false
          )
        end

        Process.put(@key, %{})

        try do
          fun.()
        after
          Process.delete(@key)
        end
      end)
    end
  end

  @doc "Whether this process is inside a memoizing decision batch."
  @spec active?() :: boolean()
  def active?, do: is_map(Process.get(@key))

  @doc "The read's memoized result inside a batch, or a fresh read outside one."
  @spec fetch(term(), (-> value)) :: value when value: term()
  def fetch(key, read) when is_function(read, 0) do
    case Process.get(@key) do
      %{^key => value} ->
        value

      %{} ->
        value = read.()
        Process.put(@key, Map.put(Process.get(@key), key, value))
        value

      nil ->
        read.()
    end
  end

  @doc "Record batched read results inside a batch; a no-op outside one."
  @spec prime(%{term() => term()}) :: :ok
  def prime(values) when is_map(values) do
    case Process.get(@key) do
      %{} = memo -> Process.put(@key, Map.merge(values, memo))
      nil -> :ok
    end

    :ok
  end
end
