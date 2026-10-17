defmodule Marshall.Agents.TurnCoordinatorTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Agents
  alias Marshall.Agents.{AuditEvent, Conversation, Event, Root, Thread, Turn, TurnCoordinator}
  alias Marshall.Compute
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes}

  setup do
    host_fixture()
    actor = user()
    {:ok, vm} = Compute.provision(request(), actor: actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)

    event = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: 1,
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    {:ok, parsed} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    {:ok, _} =
      Ledger.transaction(fn ->
        Ledger.lock!(Host, vm.host_id)
        Outcomes.ingest_locked!(vm.host_id, [parsed])
      end)

    [root] = Ledger.read!(Root, vm_id: vm.id)
    [thread] = Ledger.read!(Thread, root_id: root.id)
    %{actor: actor, vm: vm, thread: thread}
  end

  test "one thread has one running turn while a child runs independently", c do
    assert {:ok, %{turn_id: first_id}} =
             Agents.submit_prompt(
               %{thread_id: c.thread.id, prompt: "first", request_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert {:ok, %{turn_id: second_id}} =
             Agents.submit_prompt(
               %{thread_id: c.thread.id, prompt: "second", request_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert {:ok, %{id: ^first_id, status: :running}} = TurnCoordinator.claim_next()
    assert {:ok, nil} = TurnCoordinator.claim_next()

    assert {:ok, child} = Conversation.spawn_child(c.thread.id, "Investigate", c.actor)

    assert {:ok, %{turn_id: child_turn_id}} =
             Agents.submit_prompt(
               %{thread_id: child.id, prompt: "child", request_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert {:ok, %{id: ^child_turn_id, status: :running}} = TurnCoordinator.claim_next()
    assert {:ok, %{status: :completed}} = TurnCoordinator.finish(first_id, :completed, "done")
    assert {:error, :stale_turn} = TurnCoordinator.finish(first_id, :completed, "again")
    assert {:ok, %{id: ^second_id, status: :running}} = TurnCoordinator.claim_next()

    assert {:ok, %{status: :failed}} =
             TurnCoordinator.finish(child_turn_id, :failed, :provider_failed)

    assert [%{kind: :turn_finished, outcome: :completed}] =
             Ledger.read!(AuditEvent, turn_id: first_id, kind: :turn_finished)

    assert [%{kind: :assistant, body: %{"text" => "done"}}] =
             Ledger.read!(Event, turn_id: first_id, kind: :assistant)

    assert [%{status: :running}] = Ledger.read!(Turn, id: second_id)
  end

  test "a queued prompt fails after its actor loses VM access", c do
    member = user()

    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: c.vm.id,
                 email: to_string(member.email),
                 role: :operator,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.actor
             )

    assert {:ok, %{turn_id: turn_id}} =
             Agents.submit_prompt(
               %{thread_id: c.thread.id, prompt: "work", request_key: Ash.UUID.generate()},
               actor: member
             )

    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: c.vm.id,
                 email: to_string(member.email),
                 role: :revoked,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.actor
             )

    assert {:ok, nil} = TurnCoordinator.claim_next()

    assert [%{status: :failed, failure_reason: :access_revoked}] =
             Ledger.read!(Turn, id: turn_id)
  end
end
