defmodule Marshall.Agents.ThreadToolDispatch do
  @moduledoc """
  Executes one server-owned `thread` or `message_board` command.

  `Marshall.Agents.ServerToolJob` runs it per command inside a transaction; the
  lock order, authority checks, dispatch and result shape are those of the
  former polling worker.
  """
  alias Marshall.Agents.{Capabilities, Command, Root, ThreadTool, Turn}
  alias Marshall.Compute.Ledger

  @tools [:thread, :message_board]

  @doc "The command tools this module executes."
  @spec tools() :: [atom()]
  def tools, do: @tools

  # @cc [owner:ghuntley,label:concurrency;security] server-tool-claim-transaction
  # Server-owned thread commands MUST be selected and executed
  # under a database row lock and only for the thread's current running turn.
  @doc "Runs one queued command; the caller MUST hold an open transaction."
  @spec run_locked(String.t()) :: term()
  def run_locked(command_id) do
    case Ledger.read!(Command, id: command_id) do
      [%Command{status: :queued, tool: tool} = candidate] when tool in @tools ->
        claim_candidate(candidate)

      _ ->
        :ok
    end
  end

  # @cc [owner:ghuntley,label:concurrency] server-tool-lock-order
  # Command rows MUST be locked after current VM authority. Candidate selection
  # MUST NOT itself claim a command.
  @spec claim_candidate(Command.t()) :: term()
  defp claim_candidate(candidate) do
    if candidate.tool == :thread and candidate.arguments["operation"] == "subscribe" do
      source = Marshall.Agents.MessageBoardTool.target(candidate)

      [candidate.arguments["thread_id"], source && source.id]
      |> Enum.filter(&OverallsProtocol.uuid?/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.each(&Ledger.lock_history!(Marshall.Threads.Thread, &1))
    end

    board_target =
      if candidate.tool == :message_board do
        case Marshall.Agents.MessageBoardTool.target(candidate) do
          nil -> nil
          target -> Ledger.lock_history!(Marshall.Threads.Thread, target.id)
        end
      end

    case candidate.arguments do
      %{"operation" => operation, "thread_id" => id} when operation in ["subscribe", "replay"] ->
        if OverallsProtocol.uuid?(id),
          do: Ledger.lock_history!(Marshall.Threads.Thread, id)

      _ ->
        :ok
    end

    turn = Ledger.lock!(Turn, candidate.turn_id)
    thread = Ledger.lock!(Marshall.Agents.Thread, candidate.thread_id)

    if turn && thread && turn.status == :running && thread.active_turn_id == turn.id do
      authorized = authorized?(candidate, turn.actor_id)
      command = Ledger.lock!(Command, candidate.id)

      if command && command.status == :queued && command.arguments == candidate.arguments do
        result =
          if authorized,
            do: dispatch_command(command, turn.actor_id, board_target),
            else: {:error, :access_revoked}

        finish(command, result)
      end
    end
  end

  @spec finish(Command.t(), {:ok, term()} | {:error, atom()}) :: Command.t()
  defp finish(command, result) do
    {status, payload} =
      case result do
        {:ok, value} -> {:completed, %{items: List.wrap(value)}}
        {:error, reason} -> {:failed, %{reason: Atom.to_string(reason)}}
      end

    finished = Ledger.update!(command, :transition, %{status: status, result: payload})
    [root] = Ledger.read!(Root, id: command.root_id)
    [turn] = Ledger.read!(Turn, id: command.turn_id)

    Ledger.create!(Marshall.Agents.AuditEvent, :record, %{
      vm_id: root.vm_id,
      thread_id: command.thread_id,
      turn_id: command.turn_id,
      actor_id: turn.actor_id,
      kind: :tool_finished,
      target_id: command.id,
      outcome: status
    })

    finished
  end

  @spec authorized?(Command.t(), String.t()) :: boolean()
  defp authorized?(command, owner_id) do
    with [%Root{vm_id: vm_id}] <- Ledger.read!(Root, id: command.root_id),
         %Marshall.Compute.VirtualMachine{} = vm <-
           Ledger.lock!(Marshall.Compute.VirtualMachine, vm_id),
         %Marshall.Accounts.User{active: true, deleted_at: nil} = actor <-
           Marshall.Accounts.Security.current(owner_id) do
      vm.archived_at == nil and vm.desired_state == :running and
        vm.observed_state == :running and Capabilities.allowed?(vm.profile, command.tool) and
        Marshall.Access.Authorization.allowed?(vm, actor, "write")
    else
      _ -> false
    end
  end

  @spec dispatch_tool(atom(), String.t(), map()) :: {:ok, term()} | {:error, atom()}
  defp dispatch_tool(:thread, owner_id, %{"operation" => operation} = args)
       when operation in ["search", "read", "subscribe", "replay"], do: dispatch(owner_id, args)

  defp dispatch_tool(_, _, _), do: {:error, :invalid_operation}

  @spec dispatch_command(Command.t(), String.t(), Marshall.Threads.Thread.t() | nil) ::
          {:ok, term()} | {:error, atom()}
  defp dispatch_command(%{tool: :message_board} = command, actor, target),
    do: Marshall.Agents.MessageBoardTool.execute(command, actor, target)

  defp dispatch_command(
         %{tool: :thread, arguments: %{"operation" => "subscribe", "thread_id" => id} = args} =
           command,
         actor,
         _target
       ),
       do:
         Marshall.Agents.ThreadDelivery.register(
           command,
           actor,
           id,
           Map.get(args, "active", true)
         )

  defp dispatch_command(
         %{tool: :thread, arguments: %{"operation" => "replay"} = args} = command,
         actor,
         _target
       ),
       do: Marshall.Agents.ThreadDelivery.replay(command, actor, args)

  defp dispatch_command(command, actor, _target),
    do: dispatch_tool(command.tool, actor, command.arguments)

  defp dispatch(owner_id, %{"operation" => "search"} = args),
    do: ThreadTool.search(owner_id, Map.get(args, "query"), Map.get(args, "limit", 50))

  defp dispatch(owner_id, %{"operation" => "read", "thread_id" => thread_id}),
    do: ThreadTool.read(owner_id, thread_id)

  defp dispatch(owner_id, %{"operation" => "subscribe", "thread_id" => thread_id} = args),
    do: ThreadTool.subscribe(owner_id, thread_id, Map.get(args, "active", true))

  defp dispatch(owner_id, %{"operation" => "replay", "thread_id" => thread_id} = args),
    do:
      ThreadTool.replay(
        owner_id,
        thread_id,
        Map.get(args, "cursor", 0),
        Map.get(args, "limit", 100)
      )

  defp dispatch(_, _), do: {:error, :invalid_operation}
end
