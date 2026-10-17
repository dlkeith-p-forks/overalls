defmodule Marshall.ThreadsControlsTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures

  alias Marshall.Agents.{PlanProposal, Turn}
  alias Marshall.Agents.Thread, as: AgentThread
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Threads
  alias Marshall.Threads.{ProvisionWorker, Thread}

  test "initial planning settings remain part of create replay after mode changes" do
    owner = user()
    args = arguments(collaboration_mode: :plan, selected_skill_ids: [String.duplicate("a", 64)])
    assert {:ok, thread} = Threads.create_thread(args, actor: owner)
    assert thread.collaboration_mode == :plan
    assert thread.initial_skill_ids == args.selected_skill_ids

    assert {:ok, %{collaboration_mode: :work}} =
             Threads.set_collaboration_mode(%{thread_id: thread.id, collaboration_mode: :work},
               actor: owner
             )

    assert {:ok, replayed} = Threads.create_thread(args, actor: owner)
    assert replayed.id == thread.id
    assert replayed.collaboration_mode == :work

    assert_error(
      Threads.create_thread(%{args | collaboration_mode: :work}, actor: owner),
      :idempotency_conflict
    )

    assert_error(
      Threads.create_thread(%{args | selected_skill_ids: []}, actor: owner),
      :idempotency_conflict
    )
  end

  test "a viewer reads controls and context but cannot change collaboration mode" do
    owner = user()
    viewer = user()
    stranger = user()
    assert {:ok, thread} = Threads.create_thread(arguments(), actor: owner)
    grant(thread, owner, viewer, :viewer)

    assert {:ok, %{collaboration_mode: :work, busy: false}} =
             Threads.thread_controls(%{thread_id: thread.id}, actor: viewer)

    assert {:ok, %{status: :pending, usage: %{input_tokens: nil}}} =
             Threads.context_info(%{thread_id: thread.id}, actor: viewer)

    assert_error(
      Threads.set_collaboration_mode(%{thread_id: thread.id, collaboration_mode: :plan},
        actor: viewer
      ),
      :forbidden
    )

    assert_error(Threads.thread_controls(%{thread_id: thread.id}, actor: stranger), :forbidden)
  end

  test "provisioning captures collaboration separately from reasoning and busy mode changes refuse" do
    owner = user()

    assert {:ok, thread} =
             Threads.create_thread(arguments(collaboration_mode: :plan, mode: :high),
               actor: owner
             )

    thread = ready(thread)
    [turn] = Ledger.read!(Turn, thread_id: thread.agent_thread_id)
    assert turn.collaboration_mode == :plan
    assert turn.mode == :high

    assert_error(
      Threads.set_collaboration_mode(%{thread_id: thread.id, collaboration_mode: :work},
        actor: owner
      ),
      :thread_busy
    )

    Ledger.update!(turn, :transition, %{status: :completed, finished_at: Ledger.now()})

    assert {:ok, %{collaboration_mode: :work, busy: false}} =
             Threads.set_collaboration_mode(%{thread_id: thread.id, collaboration_mode: :work},
               actor: owner
             )

    [agent] = Ledger.read!(AgentThread, id: thread.agent_thread_id)
    assert agent.mode == :high
  end

  test "implement plan preserves machine and binds one Work turn on replay" do
    owner = user()

    assert {:ok, thread} =
             Threads.create_thread(arguments(collaboration_mode: :plan), actor: owner)

    thread = ready(thread)
    [turn] = Ledger.read!(Turn, thread_id: thread.agent_thread_id)
    Ledger.update!(turn, :transition, %{status: :completed, finished_at: Ledger.now()})
    text = "Inspect the existing route, implement the change, and verify the response."

    proposal =
      Ledger.create!(PlanProposal, :record, %{
        thread_id: thread.agent_thread_id,
        turn_id: turn.id,
        event_sequence: 2,
        text: text,
        digest: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
      })

    args = %{thread_id: thread.id, plan_id: proposal.id, request_key: Ash.UUID.generate()}
    assert {:ok, result} = Threads.implement_plan(args, actor: owner)
    assert {:ok, replayed} = Threads.implement_plan(args, actor: owner)
    assert replayed.turn_id == result.turn_id
    [implementation] = Ledger.read!(Turn, id: result.turn_id)
    assert implementation.collaboration_mode == :work
    assert implementation.thread_id == thread.agent_thread_id
    assert implementation.prompt == "Implement the following plan:\n\n" <> text
    [current] = Ledger.read!(Thread, id: thread.id)
    assert current.machine_id == thread.machine_id
    assert current.agent_thread_id == thread.agent_thread_id
    assert current.collaboration_mode == :work
    assert length(Ledger.read!(Turn, thread_id: thread.agent_thread_id)) == 2
  end

  test "context maintenance uses an idempotent turn without a fabricated prompt" do
    owner = user()
    assert {:ok, thread} = Threads.create_thread(arguments(), actor: owner)
    thread = ready(thread)
    [initial] = Ledger.read!(Turn, thread_id: thread.agent_thread_id)
    Ledger.update!(initial, :transition, %{status: :completed, finished_at: Ledger.now()})
    args = %{thread_id: thread.id, request_key: Ash.UUID.generate()}
    assert {:ok, compacted} = Threads.compact_context(args, actor: owner)
    assert {:ok, replayed} = Threads.compact_context(args, actor: owner)
    assert compacted.turn_id == replayed.turn_id
    [turn] = Ledger.read!(Turn, id: compacted.turn_id)
    assert turn.maintenance_kind == :compact_context
    assert turn.prompt == nil
  end

  test "a stale agent binding cannot expose controls or context" do
    owner = user()
    assert {:ok, thread} = Threads.create_thread(arguments(), actor: owner)
    thread = ready(thread)
    Ledger.update!(thread, :bind_machine, %{agent_root_id: Ash.UUID.generate()})

    assert_error(
      Threads.thread_controls(%{thread_id: thread.id}, actor: owner),
      :machine_unavailable
    )

    assert_error(
      Threads.context_info(%{thread_id: thread.id}, actor: owner),
      :machine_unavailable
    )
  end

  @spec arguments(keyword()) :: map()
  defp arguments(options \\ []) do
    request = request()

    Map.merge(
      %{
        objective: "Improve the workspace",
        mode: :medium,
        machine_spec: request,
        idempotency_key: request.idempotency_key
      },
      Map.new(options)
    )
  end

  @spec ready(Thread.t()) :: Thread.t()
  defp ready(thread) do
    host_fixture()
    args = %{"thread_id" => thread.id, "machine_key" => thread.machine_key}
    assert {:snooze, _} = ProvisionWorker.perform(%Oban.Job{args: args})
    [vm] = Ledger.read!(VirtualMachine, idempotency_key: thread.machine_key)
    Ledger.update!(vm, :observe, %{observed_state: :running})
    assert :ok = ProvisionWorker.perform(%Oban.Job{args: args})
    [ready] = Ledger.read!(Thread, id: thread.id)
    ready
  end

  @spec grant(Thread.t(), Marshall.Accounts.User.t(), Marshall.Accounts.User.t(), atom()) :: :ok
  defp grant(thread, owner, target, role) do
    assert {:ok, _} =
             Threads.set_access(
               %{
                 thread_id: thread.id,
                 email: to_string(target.email),
                 role: role,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    :ok
  end

  @spec assert_error({:error, term()}, atom()) :: :ok
  defp assert_error({:error, error}, reason) do
    assert Threads.error_reason(error) == reason
    :ok
  end
end
