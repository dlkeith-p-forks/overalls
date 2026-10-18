defmodule Marshall.Agents.ExecutorSession do
  @moduledoc "Trusted VM-bound executor lease and fenced tool result coordinator."
  alias Marshall.Agents.{AuditEvent, Command, Executor, Root}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  require Ash.Query
  require Marshall.Events

  @lease_seconds 30
  @capabilities ["context-v1", "skills-v1", "github-tools-v1"]
  @internal_tools [:context_inventory, :context_read, :skill_install, :skill_status]

  @type capability :: String.t()

  @spec valid_capabilities?(term()) :: boolean()
  def valid_capabilities?(capabilities) when is_list(capabilities) do
    length(capabilities) <= length(@capabilities) and
      length(Enum.uniq(capabilities)) == length(capabilities) and
      Enum.all?(capabilities, &(&1 in @capabilities))
  end

  def valid_capabilities?(_), do: false

  @spec supported?(Executor.t(), term()) :: boolean()
  def supported?(%Executor{capabilities: capabilities}, tool)
      when is_list(capabilities) and tool in [:context_inventory, :context_read],
      do: "context-v1" in capabilities

  def supported?(%Executor{capabilities: capabilities}, tool)
      when is_list(capabilities) and tool in [:skill_install, :skill_status],
      do: "skills-v1" in capabilities

  def supported?(%Executor{}, tool) when tool in [:exec_command, :read_file, :web_fetch], do: true
  def supported?(_, _), do: false

  # @cc [owner:ghuntley,label:security;recovery] executor-current-binding-fence
  # A lease may be issued only for Lilly's authenticated pre-NAT binding of the
  # VM's current host, placement and execution epoch. Replacing a lease MUST
  # invalidate its predecessor before accepting new tool results.

  # @cc [owner:ghuntley,label:security] executor-registration-owner-authority
  # Registration MUST fail closed with :access_revoked when the root owner is
  # deleted or no longer holds current VM write authority, and it MUST emit the
  # catalogued registration-refusal event. A revoked authority MUST NOT mint
  # fresh executor leases.
  @spec register(map(), binary() | nil, [capability()]) ::
          {:ok, Executor.t()} | {:error, term()}
  def register(binding, digest \\ nil, capabilities \\ []) do
    with true <- valid_capabilities?(capabilities),
         {:ok, parsed} <- OverallsProtocol.PrivateServices.binding(binding) do
      result =
        Ledger.transaction(fn ->
          vm = Ledger.lock!(VirtualMachine, parsed.vm_id) || Ledger.rollback(:machine_unavailable)
          current_binding!(vm, parsed)
          [root] = Ledger.read!(Root, vm_id: vm.id)

          owner = Marshall.Accounts.Security.current(root.owner_id)

          unless match?(%Marshall.Accounts.User{deleted_at: nil}, owner) and
                   Marshall.Access.Authorization.allowed?(vm, owner, "write"),
                 do: Ledger.rollback(:access_revoked)

          sessions =
            Executor
            |> Ash.Query.filter(root_id == ^root.id and is_nil(invalidated_at))
            |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())

          fence = next_fence!(root.id)

          Enum.each(sessions, fn session ->
            if session.invalidated_at == nil do
              Ledger.update!(session, :invalidate, %{invalidated_at: Ledger.now()})
              retire_commands!(session)
            end
          end)

          executor =
            Ledger.create!(Executor, :register, %{
              root_id: root.id,
              vm_id: vm.id,
              placement_id: parsed.placement_id,
              execution_epoch: parsed.execution_epoch,
              fence_epoch: fence,
              expires_at: DateTime.add(Ledger.now(), @lease_seconds, :second),
              binary_sha256: digest,
              capabilities: Enum.sort(capabilities)
            })

          if is_binary(digest) and
               Enum.any?(sessions, &(&1.binary_sha256 != digest)) do
            Ledger.create!(AuditEvent, :record, %{
              vm_id: vm.id,
              kind: :executor_updated,
              target_id: executor.id,
              outcome: :accepted
            })
          end

          Ledger.after_commit(fn ->
            Marshall.Events.emit("agent.executor_registered",
              vm_id: vm.id,
              executor_id: executor.id
            )
          end)

          executor
        end)

      case result do
        {:error, :access_revoked} ->
          Marshall.Events.emit("agent.executor_registration_refused",
            vm_id: parsed.vm_id,
            reason: :access_revoked
          )

        _ ->
          :ok
      end

      result
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  end

  @spec heartbeat(map(), String.t(), pos_integer()) ::
          {:ok, Executor.t()} | {:error, term()}
  def heartbeat(binding, executor_id, fence) do
    with {:ok, parsed} <- OverallsProtocol.PrivateServices.binding(binding) do
      Ledger.transaction(fn ->
        executor = valid_lease!(parsed, executor_id, fence)

        Ledger.update!(executor, :heartbeat, %{
          expires_at: DateTime.add(Ledger.now(), @lease_seconds, :second)
        })
      end)
    end
  end

  @spec claim(map(), String.t(), pos_integer()) ::
          {:ok, Command.t() | nil} | {:error, term()}
  def claim(binding, executor_id, fence) do
    with {:ok, parsed} <- OverallsProtocol.PrivateServices.binding(binding) do
      result = Ledger.transaction(fn -> claim!(parsed, executor_id, fence) end)

      case result do
        {:error, :access_revoked} ->
          Marshall.Events.emit("agent.executor_claim_refused",
            vm_id: parsed.vm_id,
            reason: :access_revoked
          )

        _ ->
          :ok
      end

      result
    end
  end

  @spec claim!(map(), String.t(), pos_integer()) :: Command.t() | nil
  defp claim!(parsed, executor_id, fence) do
    executor = valid_lease!(parsed, executor_id, fence)

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        """
        SELECT c.id FROM agent_commands AS c
        JOIN agent_turns AS t ON t.id = c.turn_id AND t.thread_id = c.thread_id
        JOIN agent_threads AS th ON th.id = c.thread_id AND th.root_id = c.root_id
        WHERE c.root_id = $1 AND c.status = 'queued' AND c.tool != 'web_search'
          AND t.status = 'running'
          AND th.active_turn_id = t.id
        ORDER BY c.inserted_at, c.id
        LIMIT 1 FOR UPDATE OF c SKIP LOCKED
        """,
        [Ecto.UUID.dump!(executor.root_id)],
        log: false
      )

    command =
      case rows do
        [[raw_id]] -> Ledger.lock!(Command, Ecto.UUID.load!(raw_id))
        [] -> nil
      end

    if command do
      current_authority!(executor, command)

      case eligibility(executor, command) do
        :ok ->
          claimed =
            Ledger.update!(command, :transition, %{
              status: :claimed,
              executor_id: executor.id,
              fence_epoch: fence
            })

          Ledger.create!(AuditEvent, :record, %{
            vm_id: executor.vm_id,
            thread_id: claimed.thread_id,
            turn_id: claimed.turn_id,
            kind: :tool_dispatched,
            target_id: claimed.id,
            outcome: :accepted
          })

          claimed

        {:error, reason} ->
          refuse_command!(executor, command, reason)
          nil
      end
    end
  end

  # @cc [owner:ghuntley,label:recovery] agent-orphaned-command-retirement
  # A queued tool command whose turn is already terminal can never be claimed
  # again. The loop MUST retire it to one closed terminal status with its audit
  # receipt; queue rows MUST NOT linger indefinitely behind a dead turn.
  @spec reap_orphaned() :: :ok
  def reap_orphaned do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        """
        SELECT c.id FROM agent_commands AS c
        JOIN agent_turns AS t ON t.id = c.turn_id AND t.thread_id = c.thread_id
        WHERE c.status = 'queued'
          AND t.status NOT IN ('queued', 'running')
        ORDER BY c.inserted_at, c.id
        LIMIT 128
        """,
        [],
        log: false
      )

    Enum.each(rows, fn [raw_id] -> reap_orphaned_one(Ecto.UUID.load!(raw_id)) end)
    :ok
  end

  defp reap_orphaned_one(id) do
    Ledger.transaction(fn ->
      command = Ledger.lock!(Command, id)

      with %Command{status: :queued} <- command,
           [turn] <- Ledger.read!(Marshall.Agents.Turn, id: command.turn_id),
           true <- turn.status in [:completed, :failed, :interrupted],
           [root] <- Ledger.read!(Root, id: command.root_id) do
        Ledger.update!(command, :transition, %{
          status: :cancelled,
          result: %{"reason" => "turn_finished"}
        })

        Ledger.create!(AuditEvent, :record, %{
          vm_id: root.vm_id,
          thread_id: command.thread_id,
          turn_id: command.turn_id,
          kind: :tool_finished,
          target_id: command.id,
          outcome: :failed
        })

        Ledger.after_commit(fn ->
          Marshall.Events.emit("agent.command_finished",
            vm_id: root.vm_id,
            command_id: command.id,
            outcome: :cancelled
          )
        end)

        :ok
      else
        _ -> :ok
      end
    end)

    :ok
  end

  @spec transition(map(), String.t(), pos_integer(), String.t(), atom(), map()) ::
          {:ok, Command.t()} | {:error, term()}
  def transition(binding, executor_id, fence, command_id, state, result \\ %{})

  def transition(binding, executor_id, fence, command_id, state, result)
      when state in [:started, :completed, :failed, :uncertain] and is_map(result) do
    with {:ok, parsed} <- OverallsProtocol.PrivateServices.binding(binding) do
      Ledger.transaction(fn ->
        executor = valid_lease!(parsed, executor_id, fence)
        command = Ledger.lock!(Command, command_id) || Ledger.rollback(:not_found)

        unless command.executor_id == executor.id and command.fence_epoch == fence and
                 command.root_id == executor.root_id and legal?(command.status, state),
               do: Ledger.rollback(:stale_fence)

        if state == :started do
          current_authority!(executor, command)

          case eligibility(executor, command) do
            :ok -> :ok
            {:error, reason} -> Ledger.rollback(reason)
          end
        end

        [vm] = Ledger.read!(VirtualMachine, id: executor.vm_id)
        Marshall.Compute.Idle.touch_locked!(vm)
        command = Ledger.update!(command, :transition, %{status: state, result: result})

        if state in [:completed, :failed, :uncertain] do
          Ledger.create!(AuditEvent, :record, %{
            vm_id: executor.vm_id,
            thread_id: command.thread_id,
            turn_id: command.turn_id,
            kind: :tool_finished,
            target_id: command.id,
            outcome: state
          })

          Ledger.after_commit(fn ->
            Marshall.Events.emit("agent.command_finished",
              vm_id: executor.vm_id,
              command_id: command.id,
              outcome: state
            )
          end)
        end

        command
      end)
    end
  end

  def transition(_, _, _, _, _, _), do: {:error, :invalid_transition}

  # @cc [owner:ghuntley,label:security;protocol] executor-internal-capability-fence
  # Internal context and skill commands MUST require their persisted executor
  # capability and version-one arguments at both claim and start. Unsupported
  # queued commands MUST end with a closed refusal without reaching the guest.
  @spec eligibility(Executor.t(), Command.t()) :: :ok | {:error, atom()}
  defp eligibility(executor, command) do
    cond do
      not supported?(executor, command.tool) ->
        {:error, :executor_upgrade_required}

      command.tool in @internal_tools and command.arguments["version"] !== 1 ->
        {:error, :invalid_internal_command}

      true ->
        :ok
    end
  end

  @spec current_authority!(Executor.t(), Command.t()) :: :ok
  defp current_authority!(executor, command) do
    [turn] = Ledger.read!(Marshall.Agents.Turn, id: command.turn_id)
    [vm] = Ledger.read!(VirtualMachine, id: executor.vm_id)
    actor = Marshall.Accounts.Security.current(turn.actor_id)

    unless match?(%Marshall.Accounts.User{deleted_at: nil}, actor) and
             Marshall.Access.Authorization.allowed?(vm, actor, "write"),
           do: Ledger.rollback(:access_revoked)

    if command.tool in [:skill_install, :skill_status] and
         not Marshall.Agents.Skills.command_allowed?(
           command.arguments["operation_id"],
           turn.actor_id,
           vm.id
         ),
       do: Ledger.rollback(:access_revoked)

    :ok
  end

  @spec refuse_command!(Executor.t(), Command.t(), atom()) :: :ok
  defp refuse_command!(executor, command, reason) do
    Ledger.update!(command, :transition, %{
      status: :failed,
      result: %{"reason" => Atom.to_string(reason)}
    })

    Ledger.create!(AuditEvent, :record, %{
      vm_id: executor.vm_id,
      thread_id: command.thread_id,
      turn_id: command.turn_id,
      kind: :tool_finished,
      target_id: command.id,
      outcome: :failed
    })

    Ledger.after_commit(fn ->
      Marshall.Events.emit("agent.command_finished",
        vm_id: executor.vm_id,
        command_id: command.id,
        outcome: :failed
      )
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:security] maintenance-lease-lock-lifetime
  # This trusted entry MUST be called inside the host-authenticated transaction;
  # it MUST lock and revalidate the physical VM/executor binding and live root
  # owner's write authority. It grants no conversation or model tool authority.
  @spec maintenance_lease!(OverallsProtocol.PrivateServices.binding(), String.t(), pos_integer()) ::
          {Executor.t(), VirtualMachine.t()}
  def maintenance_lease!(parsed, id, fence) do
    executor = valid_lease!(parsed, id, fence)
    [vm] = Ledger.read!(VirtualMachine, id: executor.vm_id)
    [root] = Ledger.read!(Root, id: executor.root_id)
    owner = Marshall.Accounts.Security.current(root.owner_id)

    unless match?(%Marshall.Accounts.User{deleted_at: nil}, owner) and
             Marshall.Access.Authorization.allowed?(vm, owner, "write"),
           do: Ledger.rollback(:access_revoked)

    {executor, vm}
  end

  defp valid_lease!(parsed, id, fence) do
    vm = Ledger.lock!(VirtualMachine, parsed.vm_id) || Ledger.rollback(:machine_unavailable)
    current_binding!(vm, parsed)
    executor = Ledger.lock!(Executor, id) || Ledger.rollback(:stale_fence)

    unless executor.vm_id == vm.id and executor.placement_id == parsed.placement_id and
             executor.execution_epoch == parsed.execution_epoch and executor.fence_epoch == fence and
             executor.invalidated_at == nil and
             DateTime.compare(executor.expires_at, Ledger.now()) == :gt,
           do: Ledger.rollback(:stale_fence)

    executor
  end

  defp current_binding!(vm, parsed) do
    unless vm.host_id == parsed.host_id and vm.current_placement_id == parsed.placement_id and
             vm.execution_epoch == parsed.execution_epoch and vm.desired_state == :running and
             vm.observed_state == :running and
             vm.profile in [:oss, :standard, :inception] and
             Marshall.Compute.Images.guest_capabilities(vm.image_id).agents,
           do: Ledger.rollback(:stale_execution)
  end

  defp retire_commands!(session) do
    for command <-
          Command
          |> Ash.Query.filter(executor_id == ^session.id and status in [:claimed, :started])
          |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute()) do
      status = if command.status == :started, do: :uncertain, else: :cancelled
      Ledger.update!(command, :transition, %{status: status})
    end
  end

  defp next_fence!(root_id) do
    %{rows: [[fence]]} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "SELECT COALESCE(MAX(fence_epoch), 0) + 1 FROM agent_executors WHERE root_id = $1",
        [Ecto.UUID.dump!(root_id)],
        log: false
      )

    fence
  end

  defp legal?(:claimed, :started), do: true
  defp legal?(:started, state) when state in [:completed, :failed, :uncertain], do: true
  defp legal?(_, _), do: false
end
