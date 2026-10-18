defmodule Marshall.Agents.PromptTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
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

  test "a repeated prompt key creates one turn, event and audit receipt", c do
    Hegel.check(
      fn ->
        prompt = draw("prompt", string(:alphanumeric, min_length: 1, max_length: 64))
        key = Ash.UUID.generate()
        input = %{thread_id: c.thread.id, prompt: prompt, request_key: key}
        assert {:ok, first} = Agents.submit_prompt(input, actor: c.actor)
        assert {:ok, second} = Agents.submit_prompt(input, actor: c.actor)
        assert first.turn_id == second.turn_id
        assert length(Ledger.read!(Turn, request_key: key)) == 1
        assert length(Ledger.read!(Event, turn_id: first.turn_id)) == 1
        assert length(Ledger.read!(AuditEvent, turn_id: first.turn_id)) == 1
      end,
      test_cases: 100
    )
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

  test "stopped VM prompt retries and changed payload retain one turn and wake", c do
    Hegel.check(
      fn ->
        prompt = draw("prompt", string(:alphanumeric, min_length: 1, max_length: 24))
        retries = draw("retries", integer(1..4))
        host_fixture()
        {:ok, vm} = Compute.provision(request(), actor: c.actor)
        [root] = Ledger.read!(Root, vm_id: vm.id)
        [thread] = Ledger.read!(Thread, root_id: root.id)

        assert {:ok, _} =
                 Compute.lifecycle(
                   %{vm_id: vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
                   actor: c.actor
                 )

        key = Ash.UUID.generate()
        input = %{thread_id: thread.id, prompt: prompt, request_key: key}
        assert {:ok, first} = Agents.submit_prompt(input, actor: c.actor)

        for _ <- 1..retries do
          assert {:ok, replay} = Agents.submit_prompt(input, actor: c.actor)
          assert replay.turn_id == first.turn_id
        end

        assert {:error, _} =
                 Agents.submit_prompt(%{input | prompt: prompt <> "changed"}, actor: c.actor)

        assert [%{id: turn_id, prompt: ^prompt}] = Ledger.read!(Turn, request_key: key)
        assert turn_id == first.turn_id
        assert [%{kind: :prompt, turn_id: ^turn_id}] = Ledger.read!(Event, turn_id: turn_id)

        assert [%{kind: :prompt_admitted}] =
                 Ledger.read!(AuditEvent, turn_id: turn_id, kind: :prompt_admitted)

        assert [%{kind: :wake_requested}] =
                 Ledger.read!(AuditEvent, turn_id: turn_id, kind: :wake_requested)

        assert [%{kind: :start, request_key: wake_key}] =
                 Ledger.read!(Operation, vm_id: vm.id, initiator: :agent)

        assert wake_key == "agent:" <> key
      end,
      test_cases: 100
    )
  end

  test "child thread, parent event and audit receipt are committed together", c do
    assert {:ok, child} = Conversation.spawn_child(c.thread.id, "Investigate", c.actor)
    assert child.parent_thread_id == c.thread.id
    assert {:ok, [_, %{id: child_id}]} = Conversation.list(c.vm.id, c.actor)
    assert child_id == child.id
    assert {:ok, [%{kind: :child_spawned}]} = Conversation.events(c.thread.id, c.actor)
    assert [%{kind: :child_created}] = Ledger.read!(AuditEvent, target_id: child.id)
  end

  test "a stopped VM is woken by its prompt with agent provenance", c do
    assert {:ok, _stop} =
             Compute.lifecycle(
               %{vm_id: c.vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert {:ok, %{turn_id: turn_id}} =
             Agents.submit_prompt(
               %{thread_id: c.thread.id, prompt: "resume", request_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert [%{initiator: :agent, kind: :start, requested_by_id: actor_id}] =
             Ledger.read!(Operation, vm_id: c.vm.id, initiator: :agent)

    assert actor_id == c.actor.id
    assert [%{status: :queued}] = Ledger.read!(Turn, id: turn_id)

    assert [%{kind: :wake_requested, turn_id: ^turn_id}] =
             Ledger.read!(AuditEvent, kind: :wake_requested)
  end

  test "a physically stopped VM is restarted even when desired state remains running", c do
    {:ok, _} =
      Ledger.transaction(fn ->
        [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
        Ledger.update!(vm, :observe, %{observed_state: :stopped})
      end)

    assert {:ok, %{turn_id: turn_id}} =
             Agents.submit_prompt(
               %{thread_id: c.thread.id, prompt: "restart", request_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert [%{initiator: :agent, kind: :start}] =
             Ledger.read!(Operation, vm_id: c.vm.id, initiator: :agent)

    assert [%{kind: :wake_requested, turn_id: ^turn_id}] =
             Ledger.read!(AuditEvent, kind: :wake_requested)
  end

  test "shared write roles can wake, read-only roles cannot", c do
    member = user()

    Hegel.check(
      fn ->
        role = draw("role", member_of([:web, :viewer, :operator, :manager]))

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
      end,
      test_cases: 100
    )
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
