defmodule Marshall.Agents.ThreadTool do
  @moduledoc "Bounded, metadata-only thread discovery for agent tools."
  require Ash.Query
  alias Marshall.Compute.Ledger
  alias Marshall.Agents.{ThreadSubscription, ThreadNotification}

  alias Marshall.Accounts.{Security, User}
  alias Marshall.Threads

  @type result :: %{id: String.t(), title: String.t() | nil, url: String.t()}

  # @cc [owner:ghuntley,label:security] thread-tool-user-discovery
  # Search MUST return authorized user-thread IDs and links, including shared
  # threads. Matching MUST inspect titles only, never objectives or transcript.
  # A bounded scan that cannot finish MUST fail explicitly rather than omit matches.
  @spec search(String.t(), String.t() | nil, pos_integer()) ::
          {:ok, [result()]} | {:error, atom()}
  def search(actor_id, query \\ nil, limit \\ 50)

  def search(actor_id, query, limit)
      when (is_nil(query) or is_binary(query)) and is_integer(limit) and limit in 1..100 do
    with true <- OverallsProtocol.uuid?(actor_id),
         %User{active: true, deleted_at: nil} = actor <- Security.current(actor_id) do
      search_pages(actor, if(query, do: String.downcase(query)), limit, nil, [], 10)
    else
      _ -> {:error, :forbidden}
    end
  end

  def search(_, _, _), do: {:error, :invalid_arguments}

  @spec search_pages(
          User.t(),
          String.t() | nil,
          pos_integer(),
          String.t() | nil,
          [result()],
          non_neg_integer()
        ) :: {:ok, [result()]} | {:error, atom()}
  defp search_pages(_actor, _query, _limit, _cursor, _found, 0),
    do: {:error, :search_limit_exceeded}

  defp search_pages(actor, query, limit, cursor, found, remaining) do
    case Threads.list_thread_page(%{after: cursor, limit: 100}, actor: actor) do
      {:ok, %{items: rows, next_cursor: next}} ->
        matches =
          rows
          |> Enum.filter(fn row ->
            is_nil(query) or String.contains?(String.downcase(row.title || ""), query)
          end)
          |> Enum.map(&metadata/1)

        results = found ++ matches

        if length(results) >= limit or is_nil(next),
          do: {:ok, Enum.take(results, limit)},
          else: search_pages(actor, query, limit, next, results, remaining - 1)

      _ ->
        {:error, :forbidden}
    end
  end

  # @cc [owner:ghuntley,label:security] thread-tool-authorized-transcript
  # Reads MUST resolve user-thread IDs through current thread authority and the
  # retained agent binding. Internal agent IDs MUST NOT become user-thread URLs.
  # The JSON-encoded read object MUST fit 64 KiB; larger results MUST refuse
  # explicitly without returning partial transcript content.
  @spec read(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def read(actor_id, thread_id) do
    with true <- OverallsProtocol.uuid?(actor_id) and OverallsProtocol.uuid?(thread_id),
         %User{active: true, deleted_at: nil} = actor <- Security.current(actor_id),
         [thread] <- Marshall.Compute.Ledger.history!(Threads.Thread, id: thread_id),
         true <- Threads.Authorization.allowed?(thread, actor, "read"),
         {:ok, events} <- transcript(thread, actor) do
      result =
        Map.put(
          metadata(thread),
          :events,
          Enum.map(events, &Map.take(&1, [:sequence, :kind, :body]))
        )

      if byte_size(Jason.encode!(result)) <= 65_536,
        do: {:ok, result},
        else: {:error, :result_too_large}
    else
      _ -> {:error, :forbidden}
    end
  end

  @spec transcript(Threads.Thread.t(), User.t()) ::
          {:ok, [Marshall.Agents.Event.t()]} | {:error, term()}
  defp transcript(%{agent_thread_id: nil}, _actor), do: {:ok, []}
  defp transcript(thread, actor), do: Threads.events(thread.id, actor, 100)

  @spec metadata(Threads.Thread.t()) :: result()
  defp metadata(thread), do: %{id: thread.id, title: thread.title, url: "/threads/" <> thread.id}

  # @cc [owner:ghuntley,label:security] thread-tool-subscription-authority
  # Subscription changes MUST lock the user thread and check current read authority.
  # Replays MUST check current authority and an active subscription before returning events.
  @spec subscribe(String.t(), String.t(), boolean()) :: {:ok, map()} | {:error, atom()}
  def subscribe(actor_id, thread_id, active \\ true)

  def subscribe(actor_id, thread_id, active) when is_boolean(active) do
    with_target(actor_id, thread_id, fn thread ->
      case Ledger.read!(ThreadSubscription, owner_id: actor_id, user_thread_id: thread.id) do
        [] when is_nil(thread.agent_thread_id) ->
          {:error, :machine_unavailable}

        [] ->
          Ledger.create!(ThreadSubscription, :subscribe, %{
            owner_id: actor_id,
            thread_id: thread.agent_thread_id,
            user_thread_id: thread.id,
            state: if(active, do: :active, else: :inactive)
          })

        [row] ->
          Ledger.update!(row, if(active, do: :activate, else: :deactivate), %{})
      end
      |> case do
        %ThreadSubscription{} -> {:ok, %{thread_id: thread.id, active: active}}
        error -> error
      end
    end)
  end

  def subscribe(_, _, _), do: {:error, :invalid_arguments}

  @spec replay(String.t(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, atom()}
  def replay(actor_id, thread_id, after_sequence, limit \\ 100)

  def replay(actor_id, thread_id, after_sequence, limit)
      when is_integer(after_sequence) and after_sequence >= 0 and is_integer(limit) and
             limit in 1..100 do
    with_target(actor_id, thread_id, fn thread ->
      case Ledger.read!(ThreadSubscription,
             owner_id: actor_id,
             user_thread_id: thread.id,
             state: :active
           ) do
        [_] ->
          events =
            ThreadNotification
            |> Ash.Query.filter(user_thread_id == ^thread.id and sequence > ^after_sequence)
            |> Ash.Query.sort(sequence: :asc)
            |> Ash.Query.limit(limit)
            |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
            |> Enum.map(&Map.take(&1, [:sequence, :kind, :metadata]))

          {:ok, events}

        [] ->
          {:error, :not_subscribed}
      end
    end)
  end

  def replay(_, _, _, _), do: {:error, :invalid_arguments}

  @spec with_target(String.t(), String.t(), (Threads.Thread.t() ->
                                               {:ok, term()} | {:error, atom()})) ::
          {:ok, term()} | {:error, atom()}
  defp with_target(actor_id, thread_id, fun) do
    if OverallsProtocol.uuid?(actor_id) and OverallsProtocol.uuid?(thread_id) do
      case Ledger.transaction(
             fn ->
               result =
                 with %Threads.Thread{} = thread <-
                        Ledger.lock_history!(Threads.Thread, thread_id),
                      %User{active: true, deleted_at: nil} = actor <- Security.current(actor_id),
                      true <- Threads.Authorization.allowed?(thread, actor, "read") do
                   fun.(thread)
                 else
                   _ -> {:error, :forbidden}
                 end

               %{result: result}
             end,
             {:user, actor_id}
           ) do
        {:ok, %{result: result}} -> result
        {:error, _} -> {:error, :forbidden}
      end
    else
      {:error, :forbidden}
    end
  end
end
