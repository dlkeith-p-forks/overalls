defmodule Marshall.Threads.Controls do
  @moduledoc "Current-thread authorization and durable collaboration controls."

  alias Marshall.Accounts.User
  alias Marshall.Agents.{Context, PlanProposal, Planning, PlanningQuestion, Root, Skills, Turn}
  alias Marshall.Agents.Thread, as: AgentThread
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger, VirtualMachine}
  alias Marshall.Threads.{Authorization, Thread}
  require Ash.Query

  @type controls :: %{
          collaboration_mode: :work | :plan,
          busy: boolean(),
          pending_question: PlanningQuestion.t() | nil,
          latest_plan: PlanProposal.t() | nil
        }

  # @cc [owner:ghuntley,label:security;concurrency] thread-controls-current-binding
  # Public controls MUST authorize the current high-level thread and resolve its
  # paired agent root/thread. Mutations MUST retain the high-level thread lock
  # through their effect, so a stale binding or revoked grant cannot authorize it.
  @spec execute(atom(), map(), User.t()) :: term()
  def execute(:thread_controls, %{thread_id: id}, actor) do
    thread = authorized!(id, actor, "read")
    controls(thread, agent_thread(thread))
  end

  def execute(:context_info, %{thread_id: id}, actor) do
    thread = authorized!(id, actor, "read")
    agent = agent_thread(thread)

    snapshot =
      case agent do
        nil -> nil
        agent -> Context.latest_snapshot(agent.id)
      end

    Context.info(snapshot)
    |> Map.put(:usage, context_usage(agent))
  end

  def execute(:list_skills, %{thread_id: id} = args, actor) do
    thread = authorized!(id, actor, "read")
    managed = unwrap!(Skills.list(thread.id, actor: actor))

    catalog =
      case agent_thread(thread) do
        nil -> []
        agent -> Context.info(Context.latest_snapshot(agent.id)).skill_catalog
      end

    %{
      items: Enum.take(catalog, args[:limit] || 100),
      installations: managed.items,
      next_cursor: nil
    }
  end

  def execute(:set_collaboration_mode, %{thread_id: id, collaboration_mode: mode}, actor)
      when mode in [:plan, :work] do
    thread = authorized_locked!(id, actor, "write")

    unless thread.status in [:pending, :provisioning, :ready, :failed],
      do: Ledger.rollback(:thread_not_ready)

    agent =
      case agent_thread(thread) do
        nil -> nil
        _ -> lock_agent!(thread, actor)
      end

    if agent && busy?(agent), do: Ledger.rollback(:thread_busy)

    updated = Ledger.update!(thread, :set_collaboration_mode_state, %{collaboration_mode: mode})
    agent = if agent, do: Ledger.update!(agent, :set_context, %{collaboration_mode: mode})
    controls(updated, agent)
  end

  def execute(:answer_questions, %{thread_id: id, question_id: question_id} = args, actor) do
    thread = authorized_locked!(id, actor, "write")
    agent = ready_agent!(thread)

    unless Ledger.read!(PlanningQuestion, id: question_id, thread_id: agent.id) != [],
      do: Ledger.rollback(:not_found)

    unwrap!(Planning.answer(Map.take(args, [:question_id, :answers, :request_key]), actor: actor))
  end

  # @cc [owner:ghuntley,label:durability;concurrency] thread-plan-same-machine
  # Implementing a proposal MUST switch to Work and enqueue its exact retained
  # text on the current agent thread in one transaction, without provisioning or
  # replacing the machine. A failed admission MUST roll back the mode switch.
  def execute(:implement_plan, %{thread_id: id, plan_id: plan_id, request_key: key}, actor) do
    thread = authorized_locked!(id, actor, "write")
    _agent = ready_agent!(thread)
    agent = lock_agent!(thread, actor)

    Planning.implementation_locked!(agent, plan_id, actor, key, fn _proposal, prompt ->
      Ledger.update!(thread, :set_collaboration_mode_state, %{collaboration_mode: :work})

      unwrap!(
        Marshall.Agents.submit_prompt(
          %{
            thread_id: agent.id,
            prompt: prompt,
            collaboration_mode: :work,
            request_key: key
          },
          actor: actor
        )
      )
    end)
  end

  def execute(operation, %{thread_id: id, request_key: key}, actor)
      when operation in [:compact_context, :reload_context] do
    thread = authorized_locked!(id, actor, "write")
    agent = ready_agent!(thread)

    unwrap!(
      Marshall.Agents.Prompt.maintenance(agent.id, operation, %{}, actor: actor, request_key: key)
    )
  end

  def execute(operation, %{thread_id: id} = args, actor)
      when operation in [:install_skill, :update_skill, :set_skill_enabled, :remove_skill] do
    thread = authorized_locked!(id, actor, "manage")

    result =
      case operation do
        :install_skill -> Skills.install(args, actor: actor)
        :update_skill -> Skills.update(args, actor: actor)
        :set_skill_enabled -> Skills.set_enabled(args, actor: actor)
        :remove_skill -> Skills.remove(args, actor: actor)
      end

    receipt = unwrap!(result)

    if operation in [:install_skill, :update_skill] and receipt.status == :queued do
      agent = ready_agent!(thread)

      unwrap!(
        Marshall.Agents.Prompt.maintenance(
          agent.id,
          :skill_operation,
          %{"operation_id" => receipt.id},
          actor: actor,
          request_key: "skill:" <> receipt.id
        )
      )
    end

    %{operation_id: receipt.id, installation_id: receipt.installation_id, status: receipt.status}
  end

  def execute(_, _, _), do: Ledger.rollback(:invalid_request)

  @spec authorized!(String.t(), User.t(), String.t()) :: Thread.t()
  defp authorized!(id, actor, permission) do
    case Ledger.history!(Thread, id: id) do
      [thread] ->
        Authorization.require!(thread, actor, permission)
        thread

      [] ->
        Ledger.rollback(:not_found)
    end
  end

  @spec authorized_locked!(String.t(), User.t(), String.t()) :: Thread.t()
  defp authorized_locked!(id, actor, permission) do
    thread =
      Thread
      |> Ash.Query.for_read(:history, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(actor: SystemActor.compute())

    unless thread, do: Ledger.rollback(:not_found)
    Authorization.require!(thread, actor, permission)
    thread
  end

  @spec agent_thread(Thread.t()) :: AgentThread.t() | nil
  defp agent_thread(%Thread{agent_thread_id: nil}), do: nil

  defp agent_thread(thread) do
    with [agent] <- Ledger.read!(AgentThread, id: thread.agent_thread_id),
         true <- agent.root_id == thread.agent_root_id,
         [root] <- Ledger.read!(Root, id: agent.root_id),
         true <- root.vm_id == thread.machine_id and root.owner_id == thread.creator_id do
      agent
    else
      _ -> Ledger.rollback(:machine_unavailable)
    end
  end

  @spec ready_agent!(Thread.t()) :: AgentThread.t()
  defp ready_agent!(%Thread{status: :ready} = thread),
    do: agent_thread(thread) || Ledger.rollback(:thread_not_ready)

  defp ready_agent!(_), do: Ledger.rollback(:thread_not_ready)

  # @cc [owner:ghuntley,label:concurrency] thread-control-host-before-agent-lock
  # Operations that may admit a prompt MUST retain the current host and VM locks
  # before locking the agent thread, so nested prompt wake cannot invert lifecycle
  # lock order. A changed placement or retired VM MUST refuse the operation.
  @spec lock_agent!(Thread.t(), User.t()) :: AgentThread.t()
  defp lock_agent!(thread, actor) do
    agent = agent_thread(thread) || Ledger.rollback(:machine_unavailable)

    vm =
      case Ledger.read!(VirtualMachine, id: thread.machine_id) do
        [vm] -> vm
        [] -> Ledger.rollback(:machine_unavailable)
      end

    host = Ledger.lock!(Host, vm.host_id) || Ledger.rollback(:machine_unavailable)
    current = Ledger.lock_history!(VirtualMachine, vm.id) || Ledger.rollback(:machine_unavailable)

    unless current.host_id == host.id and current.archived_at == nil and
             current.desired_state != :deleted,
           do: Ledger.rollback(:machine_unavailable)

    Marshall.Access.Authorization.require!(current, actor, "write")
    Ledger.lock!(AgentThread, agent.id) || Ledger.rollback(:machine_unavailable)
  end

  @spec busy?(AgentThread.t()) :: boolean()
  defp busy?(agent) do
    agent.active_turn_id != nil or Planning.awaiting?(agent.id) or
      Turn
      |> Ash.Query.filter(thread_id == ^agent.id and status in [:queued, :running])
      |> Ash.Query.limit(1)
      |> Ash.read!(actor: SystemActor.compute()) != []
  end

  @spec context_usage(AgentThread.t() | nil) :: map()
  defp context_usage(nil), do: %{input_tokens: nil, token_limit: nil, bytes: nil}

  defp context_usage(agent) do
    case Marshall.Agents.ModelCalls.context_usage(agent) do
      {:ok, measurement} ->
        %{
          input_tokens: if(measurement.token_limit, do: measurement.estimated_tokens),
          token_limit: measurement.token_limit,
          bytes: measurement.bytes
        }

      {:error, _} ->
        %{input_tokens: nil, token_limit: nil, bytes: nil}
    end
  end

  @spec controls(Thread.t(), AgentThread.t() | nil) :: controls()
  defp controls(thread, nil) do
    %{
      collaboration_mode: thread.collaboration_mode,
      busy: false,
      pending_question: nil,
      latest_plan: nil
    }
  end

  defp controls(_thread, agent) do
    %{
      collaboration_mode: agent.collaboration_mode,
      busy: busy?(agent),
      pending_question: Planning.pending(agent.id),
      latest_plan: Planning.latest_proposal(agent.id)
    }
  end

  @spec unwrap!({:ok, result} | {:error, term()}) :: result when result: term()
  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Ledger.rollback(Marshall.Threads.error_reason(reason))
end
