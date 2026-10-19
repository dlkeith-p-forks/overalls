defmodule Marshall.Threads.ReadMarkers do
  @moduledoc """
  Monotonic per-reader transcript positions and the unread counts derived from
  them (ADR-0222). Positions count durable agent events other than streamed
  model output, the same events the transcript shows.
  """
  use Ash.Resource.Actions.Implementation
  require Ash.Query
  alias Marshall.Compute.Ledger
  alias Marshall.Threads.{Authorization, ReadMarker, Thread}

  @type unread :: %{
          read_sequence: non_neg_integer(),
          last_sequence: non_neg_integer(),
          unread: non_neg_integer()
        }

  @impl true
  @spec run(Ash.ActionInput.t(), keyword(), map()) :: {:ok, map()} | {:error, term()}
  def run(input, _options, %{actor: %Marshall.Accounts.User{} = actor}) do
    %{thread_id: thread_id, position: position} = input.arguments

    Ledger.transaction(
      fn ->
        thread =
          case Ledger.history!(Thread, id: thread_id) do
            [%Thread{} = thread] -> thread
            _ -> Ledger.rollback(:not_found)
          end

        Authorization.require!(thread, actor, "read")

        unless is_binary(thread.agent_thread_id), do: Ledger.rollback(:thread_not_ready)

        last = last_sequence(thread.agent_thread_id)
        marker = mark!(actor.id, thread, min(position, last))
        read = marker.position

        %{
          thread_id: thread.id,
          read_sequence: read,
          last_sequence: last,
          unread: count_after(thread.agent_thread_id, read)
        }
      end,
      actor
    )
    |> case do
      {:error, reason} when is_atom(reason) ->
        {:error, Marshall.Compute.Error.exception(reason: reason)}

      result ->
        result
    end
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:durability;concurrency] read-marker-monotonic
  # A marker upsert MUST serialize on the reader and transcript and MUST NOT
  # move a stored position backwards: a smaller or equal position returns the
  # stored marker unchanged. Positions are bound to the agent transcript, so a
  # reopened thread's new transcript starts from zero.
  @doc "Advances the reader's marker to at least `position`; never moves it back."
  @spec mark!(String.t(), Thread.t(), non_neg_integer()) :: ReadMarker.t()
  def mark!(user_id, %Thread{agent_thread_id: agent_thread_id} = thread, position)
      when is_binary(user_id) and is_binary(agent_thread_id) and is_integer(position) and
             position >= 0 do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["thread-read:" <> user_id <> ":" <> agent_thread_id],
      log: false
    )

    case Ledger.read!(ReadMarker, user_id: user_id, agent_thread_id: agent_thread_id) do
      [%ReadMarker{position: stored} = marker] when stored >= position ->
        marker

      [%ReadMarker{} = marker] ->
        Ledger.update!(marker, :advance, %{position: position})

      [] ->
        Ledger.create!(ReadMarker, :record, %{
          user_id: user_id,
          thread_id: thread.id,
          agent_thread_id: agent_thread_id,
          position: position
        })
    end
  end

  @doc "Unread state for threads the caller has already authorized, keyed by thread id."
  @spec unread(String.t(), [Thread.t()]) :: %{String.t() => unread()}
  def unread(user_id, threads) when is_binary(user_id) and is_list(threads) do
    bound = Enum.filter(threads, &is_binary(&1.agent_thread_id))
    agents = Enum.map(bound, & &1.agent_thread_id)

    positions =
      if agents == [],
        do: %{},
        else:
          ReadMarker
          |> Ash.Query.filter(user_id == ^user_id and agent_thread_id in ^agents)
          |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
          |> Map.new(&{&1.agent_thread_id, &1.position})

    counts = counts(agents, positions)

    Map.new(threads, fn thread ->
      read = Map.get(positions, thread.agent_thread_id, 0)
      {last, unread} = Map.get(counts, thread.agent_thread_id, {0, 0})
      {thread.id, %{read_sequence: read, last_sequence: last, unread: unread}}
    end)
  end

  @spec counts([String.t()], %{String.t() => non_neg_integer()}) ::
          %{String.t() => {non_neg_integer(), non_neg_integer()}}
  defp counts([], _positions), do: %{}

  defp counts(agents, positions) do
    ids = Enum.map(agents, &Ecto.UUID.dump!/1)
    reads = Enum.map(agents, &Map.get(positions, &1, 0))

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        """
        SELECT t.agent_id, max(e.sequence), count(e.id) FILTER (WHERE e.sequence > t.position)
        FROM unnest($1::uuid[], $2::bigint[]) AS t(agent_id, position)
        JOIN agent_events e ON e.thread_id = t.agent_id AND e.kind <> 'model_output'
        GROUP BY t.agent_id
        """,
        [ids, reads],
        log: false
      )

    Map.new(rows, fn [id, last, unread] -> {Ecto.UUID.load!(id), {last, unread}} end)
  end

  @spec last_sequence(String.t()) :: non_neg_integer()
  defp last_sequence(agent_thread_id),
    do: window(agent_thread_id, 0) |> elem(0)

  @spec count_after(String.t(), non_neg_integer()) :: non_neg_integer()
  defp count_after(agent_thread_id, position),
    do: window(agent_thread_id, position) |> elem(1)

  @spec window(String.t(), non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  defp window(agent_thread_id, position),
    do:
      [agent_thread_id]
      |> counts(%{agent_thread_id => position})
      |> Map.get(agent_thread_id, {0, 0})
end
