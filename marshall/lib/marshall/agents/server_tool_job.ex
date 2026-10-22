defmodule Marshall.Agents.ServerToolJob do
  @moduledoc "Executes one server-owned model tool command exactly once per claim."
  use Oban.Worker,
    queue: :agent_tools,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:command_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Marshall.Events

  alias Marshall.Agents.{
    AuditEvent,
    Capabilities,
    Command,
    Root,
    ServerTool,
    ThreadToolDispatch,
    Turn
  }

  alias Marshall.Compute.{Ledger, VirtualMachine}

  @type claim ::
          :done
          | {:run, module(), struct(), ServerTool.context(), Marshall.Accounts.User.t(),
             String.t()}

  @doc "Builds the job for a queued server-tool command; insert it in the queueing transaction."
  @spec enqueue!(Command.t()) :: Oban.Job.t() | nil
  def enqueue!(%Command{tool: tool, id: id}) do
    if tool in ServerTool.tools(),
      do: %{"command_id" => id} |> new() |> Oban.insert!()
  end

  # @cc [owner:ghuntley,label:security;recovery] server-tool-claim-exclusive
  # A server-tool command MUST be claimed under its row lock while still queued
  # (or re-run under the same server claim after a crash), only for the active
  # running turn, and only after fresh capability, actor, VM-access and user
  # thread write checks. Exactly one terminal result and one finish audit row
  # MUST commit per claim; a stale claim's result is discarded.
  @impl true
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()} | {:cancel, :invalid_job}
  def perform(%Oban.Job{args: %{"command_id" => id}}) when is_binary(id) do
    case Ledger.read!(Command, id: id) do
      [%Command{tool: tool}] ->
        if tool in ThreadToolDispatch.tools(), do: dispatch(id), else: perform_typed(id)

      [] ->
        :ok
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_job}

  # `thread` and `message_board` claim, execute and finish in one transaction.
  @spec dispatch(String.t()) :: :ok | {:error, term()}
  defp dispatch(id) do
    case Ledger.transaction(fn -> ThreadToolDispatch.run_locked(id) end, {:system, nil}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec perform_typed(String.t()) :: :ok | {:error, term()}
  defp perform_typed(id) do
    case Ledger.transaction(fn -> claim!(id) end, {:system, nil}) do
      {:ok, :done} ->
        :ok

      {:ok, {:run, module, request, context, actor, claim_id}} ->
        started = System.monotonic_time()

        outcome =
          Overalls.Diagnostics.Tracing.with_span(
            "marshall.agent.server_tool",
            [tool: context.command.tool],
            fn -> execute(module, request, context, actor) end
          )

        case outcome do
          :pending -> :ok
          outcome -> finish(id, claim_id, {module, request}, outcome, started)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec claim!(String.t()) :: claim()
  defp claim!(id) do
    with %Command{} = command <- Ledger.lock!(Command, id),
         true <- claimable?(command),
         module when is_atom(module) <- Map.get(ServerTool.modules(), command.tool),
         [%Turn{} = turn] <- Ledger.read!(Turn, id: command.turn_id),
         [%Marshall.Agents.Thread{} = agent_thread] <-
           Ledger.read!(Marshall.Agents.Thread, id: command.thread_id),
         [%Root{} = root] <- Ledger.read!(Root, id: command.root_id),
         %VirtualMachine{} = vm <- Ledger.lock!(VirtualMachine, root.vm_id) do
      context = %{
        command: command,
        turn: turn,
        agent_thread: agent_thread,
        vm: vm,
        user_thread: user_thread(agent_thread.id)
      }

      case admit(module, context) do
        {:ok, actor, request} ->
          claimed =
            if command.status == :queued do
              claim_id = Ash.UUID.generate()

              updated =
                Ledger.update!(command, :transition, %{
                  status: :claimed,
                  claim_id: claim_id,
                  claimed_at: Ledger.now()
                })

              audit!(context, :tool_dispatched, :accepted)
              updated
            else
              command
            end

          {:run, module, request, %{context | command: claimed}, actor, claimed.claim_id}

        {:refuse, status, reason} ->
          Ledger.update!(command, :transition, %{
            status: status,
            result: %{"reason" => Atom.to_string(reason)}
          })

          audit!(context, :tool_finished, :failed)
          after_finish(context, status, reason)
          :done
      end
    else
      _ -> :done
    end
  end

  # A server-held claim (no executor) survives a crash and is re-executed by
  # the retry; executor-claimed and terminal commands are never touched here.
  @spec claimable?(Command.t()) :: boolean()
  defp claimable?(%Command{status: :queued}), do: true

  defp claimable?(%Command{status: :claimed, executor_id: nil, claim_id: claim_id}),
    do: is_binary(claim_id)

  defp claimable?(_), do: false

  @spec admit(module(), ServerTool.context()) ::
          {:ok, Marshall.Accounts.User.t(), struct()}
          | {:refuse, :cancelled | :failed, atom()}
  defp admit(module, %{command: command, turn: turn, agent_thread: agent_thread, vm: vm} = ctx) do
    actor = Marshall.Accounts.Security.current(turn.actor_id)

    cond do
      turn.status != :running or agent_thread.active_turn_id != turn.id ->
        {:refuse, :cancelled, :turn_inactive}

      not Capabilities.allowed?(vm.profile, command.tool) ->
        {:refuse, :cancelled, :capability_denied}

      not match?(%Marshall.Accounts.User{deleted_at: nil, active: true}, actor) or
        vm.archived_at != nil or
        not Marshall.Access.Authorization.allowed?(vm, actor, "write") or
          not user_thread_writable?(ctx.user_thread, actor) ->
        {:refuse, :cancelled, :access_revoked}

      true ->
        case module.parse(command.arguments) do
          {:ok, request} -> {:ok, actor, request}
          {:error, _} -> {:refuse, :failed, :invalid_arguments}
        end
    end
  end

  @spec user_thread_writable?(Marshall.Threads.Thread.t() | nil, Marshall.Accounts.User.t()) ::
          boolean()
  defp user_thread_writable?(nil, _actor), do: true

  defp user_thread_writable?(thread, actor),
    do: Marshall.Threads.Authorization.allowed?(thread, actor, "write")

  @spec user_thread(String.t()) :: Marshall.Threads.Thread.t() | nil
  defp user_thread(agent_thread_id) do
    case Ledger.read!(Marshall.Threads.Thread, agent_thread_id: agent_thread_id) do
      [thread] -> thread
      _ -> nil
    end
  end

  @spec execute(module(), struct(), ServerTool.context(), Marshall.Accounts.User.t()) ::
          ServerTool.outcome() | :pending
  defp execute(module, request, context, actor) do
    module.execute(request, context, actor)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> reraise error, __STACKTRACE__
    _ -> {:error, :tool_failed}
  end

  @spec finish(String.t(), String.t(), {module(), struct()}, ServerTool.outcome(), integer()) ::
          :ok
  defp finish(id, claim_id, {module, request}, outcome, started) do
    {status, result} = ServerTool.bound(outcome)

    {:ok, _} =
      Ledger.transaction(
        fn ->
          with %Command{status: :claimed, claim_id: ^claim_id} = command <-
                 Ledger.lock!(Command, id),
               [%Root{} = root] <- Ledger.read!(Root, id: command.root_id),
               %VirtualMachine{} = vm <- Ledger.lock!(VirtualMachine, root.vm_id),
               [%Turn{} = turn] <- Ledger.read!(Turn, id: command.turn_id) do
            if status == :completed, do: Marshall.Compute.Idle.touch_locked!(vm)
            Ledger.update!(command, :transition, %{status: status, result: result})

            context = %{command: command, turn: turn, vm: vm}
            audit!(context, :tool_finished, status)

            if function_exported?(module, :audit_kind, 1) do
              case module.audit_kind(request) do
                nil -> :ok
                kind -> audit!(context, kind, status)
              end
            end

            reason =
              case result do
                %{"reason" => reason} when is_binary(reason) -> reason_atom(reason)
                _ -> nil
              end

            elapsed =
              System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

            after_finish(context, status, reason, elapsed)
          end

          :ok
        end,
        {:system, nil}
      )

    :ok
  end

  @spec audit!(map(), atom(), atom()) :: AuditEvent.t()
  defp audit!(%{command: command, turn: turn, vm: vm}, kind, outcome) do
    Ledger.create!(AuditEvent, :record, %{
      vm_id: vm.id,
      thread_id: command.thread_id,
      turn_id: command.turn_id,
      actor_id: turn.actor_id,
      kind: kind,
      target_id: command.id,
      outcome: outcome
    })
  end

  @spec after_finish(map(), atom(), atom() | nil, non_neg_integer()) :: :ok
  defp after_finish(%{command: command, vm: vm}, status, reason, elapsed \\ 0) do
    Ledger.after_commit(fn ->
      Marshall.Events.emit("agent.server_tool_finished",
        vm_id: vm.id,
        command_id: command.id,
        tool: command.tool,
        outcome: status,
        reason: reason
      )

      Overalls.Diagnostics.Metrics.record(
        [:marshall, :agents, :server_tool],
        %{duration: elapsed, failed: status != :completed},
        %{tool: command.tool}
      )
    end)
  end

  # Closed refusal vocabulary; anything else is reported as tool_failed.
  @reasons ~w(turn_inactive capability_denied access_revoked invalid_arguments tool_failed
              result_too_large forbidden not_found invalid_cursor not_subscribed
              stale_base_version edit_not_found edit_ambiguous page_too_large
              publish_too_large version_too_large too_many_files invalid_path
              manifest_conflict inactive upload_refused
              staging_unavailable attachment_too_large invalid_base64 invalid_upload
              attachment_unavailable attachment_persist_failed)a

  @spec reason_atom(String.t()) :: atom()
  defp reason_atom(reason) do
    Enum.find(@reasons, :tool_failed, &(Atom.to_string(&1) == reason))
  end
end
