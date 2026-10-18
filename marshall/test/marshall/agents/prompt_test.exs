defmodule Marshall.Agents.PromptTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Agents
  alias Marshall.Agents.{AuditEvent, Conversation, Event, Root, Thread, Turn}
  alias Marshall.Compute
  alias Marshall.Compute.{Ledger, Operation, VirtualMachine}
  alias Marshall.Access

  setup do
    host_fixture()
    actor = user()
    {:ok, vm} = Compute.provision(request(), actor: actor)
    [root] = Ledger.read!(Root, vm_id: vm.id)
    [thread] = Ledger.read!(Thread, root_id: root.id)
    %{actor: actor, vm: vm, root: root, thread: thread}
  end

  test "admission registers one root and an audited root thread", c do
    assert c.root.owner_id == c.actor.id
    assert c.thread.parent_thread_id == nil

    assert [%{kind: :agent_registered, target_id: root_id}] =
             Ledger.read!(AuditEvent, vm_id: c.vm.id)

    assert root_id == c.root.id
  end

  test "reusing a key with different content is rejected", c do
    key = Ash.UUID.generate()

    assert {:ok, _} =
             Agents.submit_prompt(%{thread_id: c.thread.id, prompt: "first", request_key: key},
               actor: c.actor
             )

    assert {:error, _} =
             Agents.submit_prompt(%{thread_id: c.thread.id, prompt: "second", request_key: key},
               actor: c.actor
             )

    assert [%{prompt: "first"}] = Ledger.read!(Turn, request_key: key)
  end

  test "child thread, parent event and audit receipt are committed together", c do
    assert {:ok, child} = Conversation.spawn_child(c.thread.id, "Investigate", c.actor)
    assert child.parent_thread_id == c.thread.id
    assert {:ok, [_, %{id: child_id}]} = Conversation.list(c.vm.id, c.actor)
    assert child_id == child.id
    assert {:ok, [%{kind: :child_spawned}]} = Conversation.events(c.thread.id, c.actor)
    assert [%{kind: :child_created}] = Ledger.read!(AuditEvent, target_id: child.id)
  end

  test "a stopped VM retains prompt wake provenance until physical stop and capacity admission",
       c do
    assert {:ok, stop} =
             Compute.lifecycle(
               %{vm_id: c.vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert {:ok, %{turn_id: turn_id}} =
             Agents.submit_prompt(
               %{thread_id: c.thread.id, prompt: "resume", request_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert [%{source: :prompt, requested_by_id: actor_id} = wake] =
             Ledger.read!(Marshall.Compute.WakeRequest, vm_id: c.vm.id)

    assert actor_id == c.actor.id
    assert Ledger.read!(Operation, vm_id: c.vm.id, kind: :start) == []
    assert {:ok, :waiting} = Marshall.Compute.Wake.advance(wake.id)
    assert Ledger.read!(Operation, vm_id: c.vm.id, kind: :start) == []

    assert {:ok, _} =
             Ledger.transaction(fn ->
               Ledger.lock!(Marshall.Compute.Host, c.vm.host_id)

               Marshall.Compute.Outcomes.ingest_locked!(c.vm.host_id, [
                 %{
                   id: Ash.UUID.generate(),
                   vm_id: c.vm.id,
                   placement_id: stop.placement_id,
                   execution_epoch: stop.execution_epoch,
                   generation: stop.generation,
                   operation_id: stop.id,
                   sequence: 1,
                   state: :stopped,
                   compute_empty: true,
                   disk_present: true,
                   cleanup_complete: false,
                   reason: :none
                 }
               ])
             end)

    assert {:ok, :waiting} = Marshall.Compute.Wake.advance(wake.id)

    assert [%{initiator: :wake, kind: :start}] =
             Ledger.read!(Operation, vm_id: c.vm.id, kind: :start)

    assert [%{status: :queued}] = Ledger.read!(Turn, id: turn_id)

    assert [%{kind: :wake_requested, turn_id: ^turn_id}] =
             Ledger.read!(AuditEvent, kind: :wake_requested)
  end

  test "a physically stopped VM is restarted even when desired state remains running", c do
    {:ok, _} =
      Ledger.transaction(fn ->
        [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
        [provision] = Ledger.read!(Operation, vm_id: c.vm.id, kind: :provision)
        Ledger.update!(provision, :complete, %{})
        Ledger.update!(vm, :observe, %{observed_state: :stopped})
      end)

    assert {:ok, %{turn_id: turn_id}} =
             Agents.submit_prompt(
               %{thread_id: c.thread.id, prompt: "restart", request_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert [%{source: :prompt} = wake] =
             Ledger.read!(Marshall.Compute.WakeRequest, vm_id: c.vm.id)

    assert Ledger.read!(Operation, vm_id: c.vm.id, kind: :start) == []
    assert {:ok, :waiting} = Marshall.Compute.Wake.advance(wake.id)

    assert [%{initiator: :wake, kind: :start}] =
             Ledger.read!(Operation, vm_id: c.vm.id, kind: :start)

    assert [%{kind: :wake_requested, turn_id: ^turn_id}] =
             Ledger.read!(AuditEvent, kind: :wake_requested)
  end

  test "shared write roles can wake, read-only roles cannot", c do
    member = user()

    for role <- [:web, :viewer, :operator, :manager] do
      assert {:ok, _} =
               Access.set_access(
                 %{
                   vm_id: c.vm.id,
                   email: to_string(member.email),
                   role: role,
                   idempotency_key: Ash.UUID.generate()
                 },
                 actor: c.actor
               )

      assert {:ok, _} =
               Compute.lifecycle(
                 %{vm_id: c.vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
                 actor: c.actor
               )

      result =
        Agents.submit_prompt(
          %{thread_id: c.thread.id, prompt: "wake", request_key: Ash.UUID.generate()},
          actor: member
        )

      if role in [:operator, :manager] do
        assert {:ok, _} = result
      else
        assert {:error, _} = result
      end
    end
  end

  test "a deleted VM rejects a new prompt while retaining the root thread", c do
    assert {:ok, _delete} =
             Compute.lifecycle(
               %{vm_id: c.vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert {:error, _} =
             Agents.submit_prompt(
               %{thread_id: c.thread.id, prompt: "hello", request_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert [%Thread{}] = Ledger.read!(Thread, id: c.thread.id)
    assert [] = Ledger.read!(Turn, thread_id: c.thread.id)

    {:ok, :ok} =
      Ledger.transaction(fn ->
        [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
        Ledger.archive!(vm, :archive)
      end)

    assert {:ok, [_]} = Conversation.list(c.vm.id, c.actor)
    assert {:ok, []} = Conversation.events(c.thread.id, c.actor)
    assert {:error, :machine_unavailable} = Conversation.list(c.vm.id, user())
  end

  test "a prompt queued before VM deletion becomes explicitly unavailable", c do
    assert {:ok, %{turn_id: turn_id}} =
             Agents.submit_prompt(
               %{thread_id: c.thread.id, prompt: "pending", request_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert {:ok, _} =
             Compute.lifecycle(
               %{vm_id: c.vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert :ok = Marshall.Agents.TurnCoordinator.reap_unavailable()

    assert [%{status: :failed, failure_reason: :machine_unavailable}] =
             Ledger.read!(Turn, id: turn_id)

    assert [%{kind: :turn_failed, body: %{"reason" => "machine_unavailable"}}] =
             Ledger.read!(Event, turn_id: turn_id, kind: :turn_failed)
  end
end
