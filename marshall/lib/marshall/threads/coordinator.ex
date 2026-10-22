defmodule Marshall.Threads.Coordinator do
  @moduledoc "Authenticated high-level thread actions and lifecycle coordination."
  use Ash.Resource.Actions.Implementation
  require Ash.Query
  require Marshall.Events
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Threads.{Authorization, Generation, MachineSpec, Mode, Thread}

  @impl true
  @spec run(Ash.ActionInput.t(), keyword(), map()) :: {:ok, term()} | {:error, term()}
  def run(input, options, %{actor: %Marshall.Accounts.User{} = actor}) do
    operation = options[:operation] || input.action.name

    case Ledger.transaction(fn -> execute(operation, input.arguments, actor) end, actor) do
      {:error, reason} when is_atom(reason) ->
        {:error, Marshall.Compute.Error.exception(reason: reason)}

      result ->
        result
    end
  end

  def run(_, _, _), do: {:error, :forbidden}

  defp execute(:create_thread, args, actor) do
    with {:ok, mode} <- Mode.parse(args[:mode] || :medium),
         {:ok, spec} <- MachineSpec.from_map(args.machine_spec),
         :ok <- team_authorized(spec.team_id, actor) do
      # Serialize first-writer creation across nodes. The unique index remains
      # the final guard, while this lock lets us compare the complete request
      # before a concurrent retry observes a partial row.
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        ["thread:" <> args.idempotency_key],
        log: false
      )

      existing = Ledger.history!(Thread, idempotency_key: args.idempotency_key)
      collaboration_mode = args[:collaboration_mode] || :work
      selected_skills = args[:selected_skill_ids] || []

      case existing do
        [%Thread{} = thread] ->
          if thread.creator_id == actor.id and thread.objective == args.objective and
               thread.mode == mode and thread.team_id == spec.team_id and
               thread.initial_collaboration_mode == collaboration_mode and
               thread.initial_skill_ids == selected_skills and
               same_spec?(spec, thread.machine_spec),
             do: thread,
             else: Ledger.rollback(:idempotency_conflict)

        [] ->
          thread =
            Ledger.create!(Thread, :open, %{
              creator_id: actor.id,
              team_id: spec.team_id,
              objective: args.objective,
              mode: mode,
              collaboration_mode: collaboration_mode,
              initial_collaboration_mode: collaboration_mode,
              initial_skill_ids: selected_skills,
              machine_spec: MachineSpec.to_map(spec),
              idempotency_key: args.idempotency_key,
              machine_key: args.idempotency_key
            })

          _generation = Generation.open!(thread, 1)

          enqueue_provision!(thread)

          Ledger.after_commit(fn ->
            Marshall.Events.emit("thread.created", thread_id: thread.id)
          end)

          thread
      end
    else
      {:error, reason} -> Ledger.rollback(reason)
    end
  end

  defp execute(:list, args, actor) do
    case authorized_page(thread_query(actor), actor, args[:limit] || 100) do
      {:ok, {items, _has_more?}} -> Enum.take(items, args[:limit] || 100)
      {:error, reason} -> Ledger.rollback(reason)
    end
  end

  # @cc [owner:ghuntley,label:security;durability] thread-list-keyset-page
  # Thread pages MUST keyset paginate the same authorized query with a stable
  # inserted_at/id ordering, optionally narrowed to one machine. An unknown or
  # unauthorized cursor returns an empty page and never broadens the caller's
  # read scope.
  defp execute(:list_page, args, actor) do
    limit = args[:limit] || 50

    query =
      actor
      |> thread_query()
      |> narrow(:machine_id, args[:machine_id])
      |> narrow(:status, args[:status])
      |> narrow(:query, args[:query])

    case page_query(query, args[:after], actor) do
      {:ok, query} ->
        case authorized_page(query, actor, limit) do
          {:ok, {rows, has_more?}} ->
            items = Enum.take(rows, limit)

            %{items: items, next_cursor: if(has_more?, do: List.last(items).id)}

          {:error, reason} ->
            Ledger.rollback(reason)
        end

      :empty ->
        %{items: [], next_cursor: nil}
    end
  end

  defp execute(:get, %{thread_id: id}, actor) do
    case Ledger.history!(Thread, id: id) do
      [%Thread{} = thread] ->
        if visible?(thread, actor), do: thread, else: Ledger.rollback(:forbidden)

      _ ->
        Ledger.rollback(:not_found)
    end
  end

  defp execute(:prompt, %{thread_id: id, prompt: prompt, request_key: key} = args, actor) do
    thread = get_visible!(id, actor)
    thread = Ledger.lock_history!(Thread, thread.id) || Ledger.rollback(:not_found)
    Authorization.require!(thread, actor, "write")

    unless thread.status == :ready and is_binary(thread.agent_thread_id),
      do: Ledger.rollback(:thread_not_ready)

    parameters =
      %{thread_id: thread.agent_thread_id, prompt: prompt, request_key: key}
      |> Map.merge(Map.take(args, [:collaboration_mode, :selected_skill_ids]))

    case Marshall.Agents.submit_prompt(
           parameters,
           actor: actor
         ) do
      {:ok, result} ->
        [agent] = Ledger.read!(Marshall.Agents.Thread, id: thread.agent_thread_id)

        if agent.collaboration_mode != thread.collaboration_mode do
          Ledger.update!(thread, :set_collaboration_mode_state, %{
            collaboration_mode: agent.collaboration_mode
          })
        end

        result

      {:error, reason} ->
        Ledger.rollback(Marshall.Threads.error_reason(reason))
    end
  end

  defp execute(:delete, %{thread_id: id}, actor), do: execute(:archive, %{thread_id: id}, actor)

  defp execute(:retry, %{thread_id: id}, actor) do
    thread = get_visible!(id, actor)
    current = Ledger.lock_history!(Thread, thread.id) || Ledger.rollback(:not_found)
    Authorization.require!(current, actor, "manage")
    unless current.status in [:failed, :pending], do: Ledger.rollback(:retry_unavailable)

    retried = current |> with_admitted_machine!() |> prepare_retry!()
    enqueue_provision!(retried)
    retried
  end

  defp execute(:archive, %{thread_id: id}, actor) do
    thread = get_visible!(id, actor)

    Authorization.require!(thread, actor, "manage")

    locked = Ledger.lock_history!(Thread, thread.id) || Ledger.rollback(:not_found)
    require_management!(locked, actor)
    locked = with_admitted_machine!(locked)
    cancel_pending_question!(locked)

    case locked.status do
      status when status in [:archived, :deleting] ->
        locked

      _ when is_binary(locked.machine_id) ->
        archive_machine!(locked, actor)

      _ ->
        Ledger.update!(locked, :mark_archived, %{})
    end
  end

  defp execute(:reopen, %{thread_id: id}, actor) do
    thread = get_visible!(id, actor)

    Authorization.require!(thread, actor, "manage")

    unless thread.status == :archived, do: Ledger.rollback(:reopen_unavailable)

    current = Ledger.lock_history!(Thread, thread.id) || Ledger.rollback(:not_found)
    require_management!(current, actor)

    unless current.status == :archived, do: Ledger.rollback(:reopen_unavailable)

    reopened =
      Ledger.update!(current, :reopen, %{
        machine_key: "thread-reopen:" <> current.id <> ":" <> Ash.UUID.generate()
      })

    _generation = Generation.open_next!(reopened)

    enqueue_provision!(reopened)

    reopened
  end

  defp execute(operation, args, actor),
    do: Marshall.Threads.Controls.execute(operation, args, actor)

  @spec thread_query(Marshall.Accounts.User.t()) :: Ash.Query.t()
  defp thread_query(actor) do
    member_team_ids =
      Ledger.read!(Marshall.Teams.TeamMember, user_id: actor.id)
      |> Enum.map(& &1.team_id)

    team_ids =
      Marshall.Teams.Team
      |> Ash.Query.filter(id in ^member_team_ids)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.map(& &1.id)

    Thread
    |> Ash.Query.for_read(:history, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(
      creator_id == ^actor.id or team_id in ^team_ids or
        exists(grants, user_id == ^actor.id and is_nil(archived_at))
    )
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
  end

  # @cc [owner:ghuntley,label:security] thread-search-literal
  # A thread title or objective search MUST match the caller's text literally:
  # LIKE wildcards and the escape character are escaped, and the filter only
  # narrows the already-authorized query.
  @spec narrow(Ash.Query.t(), :machine_id | :status | :query, term()) :: Ash.Query.t()
  defp narrow(query, _field, nil), do: query
  defp narrow(query, :machine_id, id), do: Ash.Query.filter(query, machine_id == ^id)
  defp narrow(query, :status, status), do: Ash.Query.filter(query, status == ^status)

  defp narrow(query, :query, text) do
    pattern = "%" <> escape_like(text) <> "%"

    Ash.Query.filter(
      query,
      fragment("? ILIKE ? ESCAPE '\\'", title, ^pattern) or
        fragment("? ILIKE ? ESCAPE '\\'", objective, ^pattern)
    )
  end

  @doc false
  @spec escape_like(String.t()) :: String.t()
  def escape_like(text) when is_binary(text),
    do: String.replace(text, ["\\", "%", "_"], &("\\" <> &1))

  @spec page_query(Ash.Query.t(), String.t() | nil, Marshall.Accounts.User.t()) ::
          {:ok, Ash.Query.t()} | :empty
  defp page_query(query, nil, _actor), do: {:ok, query}

  defp page_query(query, cursor, actor) when is_binary(cursor) do
    case Ledger.history!(Thread, id: cursor) do
      [%Thread{} = thread] ->
        if Authorization.allowed?(thread, actor, "read") do
          {:ok,
           Ash.Query.filter(
             query,
             inserted_at < ^thread.inserted_at or
               (inserted_at == ^thread.inserted_at and id < ^thread.id)
           )}
        else
          :empty
        end

      _ ->
        :empty
    end
  end

  defp page_query(_query, _cursor, _actor), do: :empty

  @page_batch 100
  @max_page_scan 10_000

  # @cc [owner:ghuntley,label:security;durability] thread-authorized-page-bound
  # Authorized thread pagination MUST continue past post-query authorization
  # refusals so visible pages do not contain holes. It MUST stop after a fixed
  # scan budget and return a closed error rather than silently truncating or
  # exposing a cursor that could broaden the reader's scope.
  @spec authorized_page(Ash.Query.t(), Marshall.Accounts.User.t(), pos_integer()) ::
          {:ok, {[Thread.t()], boolean()}} | {:error, :authorization_scan_limit}
  defp authorized_page(query, actor, limit) do
    collect_authorized(query, actor, limit, [], 0)
  end

  @spec collect_authorized(
          Ash.Query.t(),
          Marshall.Accounts.User.t(),
          pos_integer(),
          [Thread.t()],
          non_neg_integer()
        ) :: {:ok, {[Thread.t()], boolean()}} | {:error, :authorization_scan_limit}
  defp collect_authorized(query, actor, limit, collected, scanned) do
    batch_size = min(@page_batch, limit + 1)

    rows =
      query
      |> Ash.Query.limit(batch_size)
      |> Ash.read!(actor: SystemActor.compute())

    authorized = Enum.filter(rows, &Authorization.allowed?(&1, actor, "read"))
    collected = collected ++ authorized
    scanned = scanned + length(rows)

    cond do
      length(collected) > limit ->
        {:ok, {Enum.take(collected, limit + 1), true}}

      length(rows) < batch_size ->
        {:ok, {collected, false}}

      scanned >= @max_page_scan ->
        {:error, :authorization_scan_limit}

      true ->
        last = List.last(rows)

        collect_authorized(
          after_thread(query, last),
          actor,
          limit,
          collected,
          scanned
        )
    end
  end

  @spec after_thread(Ash.Query.t(), Thread.t()) :: Ash.Query.t()
  defp after_thread(query, %Thread{} = thread) do
    Ash.Query.filter(
      query,
      inserted_at < ^thread.inserted_at or
        (inserted_at == ^thread.inserted_at and id < ^thread.id)
    )
  end

  @spec cancel_pending_question!(Thread.t()) :: :ok
  defp cancel_pending_question!(%Thread{agent_thread_id: agent_thread_id})
       when is_binary(agent_thread_id) do
    Marshall.Agents.Planning.cancel_pending_locked!(agent_thread_id, :archived)
  end

  defp cancel_pending_question!(%Thread{}), do: :ok

  @spec archive_machine!(Thread.t(), Marshall.Accounts.User.t()) :: Thread.t()
  defp archive_machine!(thread, actor) do
    case Ledger.history!(Marshall.Compute.VirtualMachine, id: thread.machine_id) do
      [%{archived_at: archived_at}] when not is_nil(archived_at) ->
        Ledger.update!(thread, :mark_archived, %{})

      [%{desired_state: :deleted}] ->
        # Deleted intent is monotone, but is not a physical deletion receipt.
        # Avoid a nested lifecycle refusal rolling back this thread transition.
        mark_deleting!(thread)

      [_vm] ->
        case Marshall.Compute.lifecycle(
               %{
                 vm_id: thread.machine_id,
                 kind: :delete,
                 idempotency_key: "thread-delete:" <> thread.machine_id
               },
               actor: actor
             ) do
          {:ok, _operation} -> mark_deleting!(thread)
          {:error, reason} -> Ledger.rollback(Marshall.Threads.error_reason(reason))
        end

      [] ->
        Ledger.rollback(:machine_unavailable)
    end
  end

  @spec same_spec?(MachineSpec.t(), map()) :: boolean()
  defp same_spec?(spec, stored) do
    case MachineSpec.from_map(stored) do
      {:ok, parsed} -> MachineSpec.to_map(spec) == MachineSpec.to_map(parsed)
      _ -> false
    end
  end

  @spec with_admitted_machine!(Thread.t()) :: Thread.t()
  defp with_admitted_machine!(%Thread{machine_id: nil, archived_at: nil} = thread) do
    case Ledger.history!(Marshall.Compute.VirtualMachine,
           owner_id: thread.creator_id,
           idempotency_key: thread.machine_key
         ) do
      [vm] -> Ledger.update!(thread, :record_admitted_machine, %{machine_id: vm.id})
      [] -> thread
    end
  end

  defp with_admitted_machine!(thread), do: thread

  @spec require_management!(Thread.t(), Marshall.Accounts.User.t()) :: :ok
  defp require_management!(thread, actor) do
    Authorization.require!(thread, actor, "manage")
  end

  @spec prepare_retry!(Thread.t()) :: Thread.t()
  defp prepare_retry!(%Thread{machine_id: nil} = thread),
    do: Ledger.update!(thread, :requeue, %{})

  defp prepare_retry!(thread) do
    case Ledger.history!(Marshall.Compute.VirtualMachine, id: thread.machine_id) do
      [%{archived_at: archived_at}] when not is_nil(archived_at) ->
        reopened =
          Ledger.update!(thread, :replace_generation, %{
            machine_key: "thread-retry:" <> thread.id <> ":" <> Ash.UUID.generate()
          })

        _generation = Generation.open_next!(reopened)
        reopened

      [%{desired_state: :deleted}] ->
        Ledger.rollback(:retry_unavailable)

      [_vm] ->
        Ledger.update!(thread, :requeue, %{})

      [] ->
        Ledger.rollback(:machine_unavailable)
    end
  end

  @spec mark_deleting!(Thread.t()) :: Thread.t()
  defp mark_deleting!(thread) do
    deleting = Ledger.update!(thread, :mark_deleting, %{})

    Marshall.Threads.ArchiveWorker.new(%{
      "thread_id" => deleting.id,
      "machine_key" => deleting.machine_key
    })
    |> Oban.insert!()

    deleting
  end

  @spec enqueue_provision!(Thread.t()) :: Oban.Job.t()
  defp enqueue_provision!(thread) do
    Marshall.Threads.ProvisionWorker.new(%{
      "thread_id" => thread.id,
      "machine_key" => thread.machine_key
    })
    |> Oban.insert!()
  end

  @spec visible?(Thread.t(), Marshall.Accounts.User.t()) :: boolean()
  defp visible?(thread, actor), do: Authorization.allowed?(thread, actor, "read")

  defp get_visible!(id, actor) do
    case Ledger.history!(Thread, id: id) do
      [%Thread{} = thread] ->
        if visible?(thread, actor), do: thread, else: Ledger.rollback(:forbidden)

      _ ->
        Ledger.rollback(:not_found)
    end
  end

  defp team_authorized(nil, _actor), do: :ok

  defp team_authorized(team_id, actor) do
    team =
      case Ledger.read!(Marshall.Teams.Team, id: team_id) do
        [team] -> team
        _ -> Ledger.rollback(:unknown_team)
      end

    Marshall.Teams.Fence.require_resources_open!(team)

    if Marshall.Authorization.Cedar.allowed?(
         actor,
         "team_manage_members",
         Marshall.Authorization.Cedar.team(team)
       ),
       do: :ok,
       else: Ledger.rollback(:forbidden)
  end
end
