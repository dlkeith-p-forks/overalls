defmodule Marshall.Agents.SkillMaintenance do
  @moduledoc "Durable skill installation turns and bounded read-only outcome reconciliation."
  alias Marshall.Accounts.Security
  alias Marshall.Agents.{Command, Prompt, SkillOperation, Skills, Thread, Turn}
  alias Marshall.Agents.Skills.Failures
  alias Marshall.Compute.Ledger
  alias Marshall.Threads.Thread, as: UserThread
  require Marshall.Events

  @type progress :: :pending | :completed | {:error, atom()}
  @max_status_attempts 3

  @doc "Recovers queued installation admissions and pinned replacement-machine restorations."
  @spec tick() :: :ok
  def tick do
    _ = tick(nil)
    :ok
  end

  # @cc [owner:ghuntley,label:concurrency;recovery] skill-restoration-progress
  # Each maintenance pass MUST report the last scanned thread as its cursor,
  # continue after restore errors, and emit only a bounded, catalogued outcome.
  # A restore error MUST NOT abort the pass or cause the same first batch to be
  # selected indefinitely.
  @spec tick(String.t() | nil) :: {:ok, String.t() | nil}
  def tick(cursor) do
    restoration_threads = Skills.restoration_threads(cursor)

    Enum.each(restoration_threads, fn thread_id ->
      case restore(thread_id) do
        {:ok, _operations} ->
          :ok

        {:error, reason} ->
          Marshall.Events.emit("agent.skill_restoration_failed",
            thread_id: thread_id,
            reason: Failures.normalize(reason)
          )
      end
    end)

    for operation <- Skills.pending(), do: enqueue(operation)

    {:ok, List.last(restoration_threads)}
  end

  @spec restore(String.t()) :: {:ok, [SkillOperation.t()]} | {:error, term()}
  defp restore(thread_id) do
    Skills.restore(thread_id)
  rescue
    _ -> {:error, :unavailable}
  end

  @spec enqueue(SkillOperation.t()) :: :ok
  defp enqueue(operation) do
    with [thread] <- Ledger.read!(UserThread, id: operation.thread_id),
         true <-
           thread.status == :ready and thread.machine_id == operation.machine_id and
             thread.machine_key == operation.machine_key,
         actor when not is_nil(actor) <- Security.current(operation.requested_by_id),
         true <- Marshall.Threads.Authorization.allowed?(thread, actor, "manage"),
         true <- is_binary(thread.agent_thread_id),
         {:ok, _} <-
           Prompt.maintenance(
             thread.agent_thread_id,
             :skill_operation,
             %{"operation_id" => operation.id},
             actor: actor,
             request_key: "skill:" <> operation.id
           ) do
      :ok
    else
      {:error, :forbidden} ->
        Skills.fail(operation.id, :access_revoked)
        :ok

      {:error, _} ->
        :ok

      _ ->
        Skills.fail(operation.id, :machine_changed)
        :ok
    end
  end

  # @cc [owner:ghuntley,label:concurrency;recovery] skill-maintenance-single-effect
  # Installation maintenance MUST create at most one skill_install command per
  # operation. Ambiguous effects MUST only be reconciled with bounded skill_status
  # reads; neither a restart nor a missing receipt may repeat installation.
  @spec advance(String.t()) :: progress()
  def advance(turn_id) do
    with [%Turn{status: :running, maintenance_kind: :skill_operation} = turn] <-
           Ledger.read!(Turn, id: turn_id),
         id when is_binary(id) <- Map.get(turn.maintenance_metadata, "operation_id"),
         [%SkillOperation{} = operation] <- Ledger.read!(SkillOperation, id: id) do
      advance_operation(turn, operation)
    else
      _ -> {:error, :skill_failed}
    end
  end

  @spec advance_operation(Turn.t(), SkillOperation.t()) :: progress()
  defp advance_operation(turn, %SkillOperation{status: :queued} = operation) do
    case Skills.dispatch(operation.id, fn user_thread, operation, arguments ->
           {turn, thread} = running!(turn.id, user_thread, operation)

           command =
             Ledger.create!(Command, :queue, %{
               root_id: thread.root_id,
               thread_id: thread.id,
               turn_id: turn.id,
               call_id: "skill-install:" <> operation.id,
               tool: :skill_install,
               arguments: arguments
             })

           command.id
         end) do
      {:ok, operation} -> outcome(operation)
      {:error, reason} -> error(reason)
    end
  end

  defp advance_operation(turn, %SkillOperation{status: :dispatched} = operation) do
    case Ledger.read!(Command, id: operation.command_id) do
      [%Command{turn_id: id, status: :completed, result: result}] when id == turn.id ->
        complete(operation, result)

      [%Command{turn_id: id, status: :failed, result: result}] when id == turn.id ->
        failed(operation, result)

      [%Command{turn_id: id, status: status}]
      when id == turn.id and status in [:uncertain, :cancelled] ->
        Skills.fail(operation.id, :uncertain)
        reconcile(turn, operation)

      [%Command{turn_id: id}] when id == turn.id ->
        :pending

      _ ->
        {:error, :skill_failed}
    end
  end

  defp advance_operation(turn, %SkillOperation{status: :uncertain} = operation),
    do: reconcile(turn, operation)

  defp advance_operation(_turn, operation), do: outcome(operation)

  @spec reconcile(Turn.t(), SkillOperation.t()) :: progress()
  defp reconcile(turn, operation) do
    commands = status_commands(turn.id, operation.id)

    case List.last(commands) do
      %Command{status: :completed, result: result} ->
        case complete(operation, result) do
          :pending -> queue_status(turn, operation)
          other -> other
        end

      %Command{status: state} when state in [:queued, :claimed, :started] ->
        :pending

      _ ->
        queue_status(turn, operation)
    end
  end

  @spec queue_status(Turn.t(), SkillOperation.t()) :: progress()
  defp queue_status(turn, operation) do
    case Skills.reconcile(operation.id, fn user_thread, operation, arguments ->
           {turn, thread} = running!(turn.id, user_thread, operation)
           commands = status_commands(turn.id, operation.id)

           cond do
             Enum.any?(commands, &(&1.status in [:queued, :claimed, :started])) ->
               :pending

             length(commands) >= @max_status_attempts ->
               {:error, :tool_uncertain}

             true ->
               Ledger.create!(Command, :queue, %{
                 root_id: thread.root_id,
                 thread_id: thread.id,
                 turn_id: turn.id,
                 call_id:
                   "skill-status:" <>
                     operation.id <> ":" <> Integer.to_string(length(commands) + 1),
                 tool: :skill_status,
                 arguments: arguments
               })

               :pending
           end
         end) do
      {:ok, %SkillOperation{} = operation} -> outcome(operation)
      {:ok, progress} -> progress
      {:error, reason} -> error(reason)
    end
  end

  @spec complete(SkillOperation.t(), term()) :: progress()
  defp complete(operation, result) do
    case Skills.complete(operation.id, result) do
      {:ok, operation} -> outcome(operation)
      {:error, reason} -> error(reason)
    end
  end

  @spec failed(SkillOperation.t(), term()) :: progress()
  defp failed(operation, result) do
    code =
      case result do
        %{"code" => code} -> code
        %{"reason" => code} -> code
        %{"error" => %{"code" => code}} -> code
        _ -> :unavailable
      end

    case Skills.fail(operation.id, code) do
      {:ok, operation} -> outcome(operation)
      {:error, reason} -> error(reason)
    end
  end

  @spec running!(String.t(), UserThread.t(), SkillOperation.t()) :: {Turn.t(), Thread.t()}
  defp running!(turn_id, user_thread, operation) do
    turn = Ledger.lock!(Turn, turn_id) || Ledger.rollback(:not_found)
    thread = Ledger.lock!(Thread, turn.thread_id) || Ledger.rollback(:not_found)

    unless turn.status == :running and turn.maintenance_kind == :skill_operation and
             turn.actor_id == operation.requested_by_id and thread.active_turn_id == turn.id and
             user_thread.agent_thread_id == thread.id and
             turn.maintenance_metadata["operation_id"] == operation.id,
           do: Ledger.rollback(:stale_operation)

    {turn, thread}
  end

  @spec status_commands(String.t(), String.t()) :: [Command.t()]
  defp status_commands(turn_id, operation_id) do
    prefix = "skill-status:" <> operation_id <> ":"

    Ledger.read!(Command, turn_id: turn_id, tool: :skill_status)
    |> Enum.filter(&String.starts_with?(&1.call_id, prefix))
    |> Enum.sort_by(& &1.call_id)
  end

  @spec outcome(SkillOperation.t()) :: progress()
  defp outcome(%SkillOperation{status: :completed}), do: :completed
  defp outcome(%SkillOperation{status: :failed, failure_reason: reason}), do: error(reason)
  defp outcome(_), do: :pending

  @spec error(term()) :: {:error, atom()}
  defp error(reason) when reason in [:access_revoked, :forbidden], do: {:error, :access_revoked}

  defp error(reason) when reason in [:machine_changed, :machine_unavailable],
    do: {:error, :machine_unavailable}

  defp error(:uncertain), do: {:error, :tool_uncertain}
  defp error(_), do: {:error, :skill_failed}
end
