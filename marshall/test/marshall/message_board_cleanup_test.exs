defmodule Marshall.MessageBoardCleanupTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Compute.Ledger
  alias Marshall.MessageBoards

  test "a machine without a user thread still loses its board posts on stop" do
    host_fixture()
    actor = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: actor)
    vm = Ledger.update!(vm, :observe, %{observed_state: :running})
    assert {:ok, _} = MessageBoards.post!(actor.id, :standard, "ordinary", "body", vm_id: vm.id)
    assert {:ok, retained} = MessageBoards.post!(actor.id, :standard, "unbound", "body")
    Ledger.update!(vm, :request_stop, %{generation: vm.generation + 1})
    assert [^retained] = MessageBoards.list!(actor.id, :standard)
  end

  @tag hegel_case_sandbox: true, timeout: 120_000
  property "machine transitions remove only their posts and retain one cleanup notification" do
    {action, state} =
      draw(
        "transition",
        member_of([
          {:request_pause, :paused},
          {:request_stop, :stopped},
          {:request_delete, :deleted}
        ])
      )

    count = draw("post count", integer(1..4))
    delivery_attempts = draw("delivery retries", integer(1..5))
    receiver_paused = draw("receiver pauses before delivery", boolean())
    permission_revoked = draw("reader loses permission before delivery", boolean())
    audit_failure = draw("delivery audit fails before commit", boolean())
    isolate_property_case()
    host_fixture()
    actor = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: actor)
    vm = Ledger.update!(vm, :observe, %{observed_state: :running})
    [root] = Ledger.read!(Marshall.Agents.Root, vm_id: vm.id)
    [agent] = Ledger.read!(Marshall.Agents.Thread, root_id: root.id)

    thread =
      Ledger.create!(Marshall.Threads.Thread, :open, %{
        creator_id: actor.id,
        objective: "Cleanup fixture",
        mode: :medium,
        machine_spec: request(),
        idempotency_key: Ecto.UUID.generate(),
        machine_key: vm.idempotency_key
      })

    thread =
      Ledger.update!(thread, :bind_machine, %{
        machine_id: vm.id,
        agent_root_id: root.id,
        agent_thread_id: agent.id,
        status: :ready
      })

    assert {:ok, _} = Marshall.Agents.ThreadTool.subscribe(actor.id, thread.id)

    subscriber = user()

    assert {:ok, _} =
             Marshall.Threads.set_access(
               %{
                 thread_id: thread.id,
                 email: to_string(subscriber.email),
                 role: :viewer,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: actor
             )

    {:ok, receiver_vm} = Marshall.Compute.provision(request(), actor: subscriber)
    receiver_vm = Ledger.update!(receiver_vm, :observe, %{observed_state: :running})
    [receiver_root] = Ledger.read!(Marshall.Agents.Root, vm_id: receiver_vm.id)
    [receiver_thread] = Ledger.read!(Marshall.Agents.Thread, root_id: receiver_root.id)

    command =
      struct(Marshall.Agents.Command, %{root_id: receiver_root.id, thread_id: receiver_thread.id})

    assert {:ok, _} =
             Ledger.transaction(fn ->
               Marshall.Agents.ThreadDelivery.register(command, subscriber.id, thread.id, true)
             end)

    assert {:ok, retained} = MessageBoards.post!(actor.id, :standard, "retained", "unbound")

    for index <- 1..count do
      assert {:ok, original} =
               MessageBoards.post!(actor.id, :standard, "post-#{index}", "body",
                 vm_id: vm.id,
                 thread_id: thread.id
               )

      assert {:ok, ^original} =
               MessageBoards.post!(actor.id, :standard, "post-#{index}", "body",
                 vm_id: vm.id,
                 thread_id: thread.id
               )
    end

    Ledger.update!(vm, action, %{generation: vm.generation + 1})
    assert [^retained] = MessageBoards.list!(actor.id, :standard)

    assert {:ok, [%{sequence: 1, kind: :machine_purged, metadata: metadata}]} =
             Marshall.Agents.ThreadTool.replay(actor.id, thread.id, 0)

    assert metadata["count"] == count
    assert metadata["vm_id"] == vm.id
    assert metadata["state"] == Atom.to_string(state)
    assert MessageBoards.purge_for_state!(vm.id, state) == 0
    assert {:ok, [_]} = Marshall.Agents.ThreadTool.replay(actor.id, thread.id, 0)

    if receiver_paused do
      paused =
        Ledger.update!(receiver_vm, :request_pause, %{generation: receiver_vm.generation + 1})

      Ledger.update!(paused, :observe, %{observed_state: :paused})
      assert {:ok, _} = Marshall.Agents.ThreadDelivery.deliver_one()
      assert [] = Ledger.read!(Marshall.Agents.Turn, thread_id: receiver_thread.id)
      [unchanged] = Ledger.read!(Marshall.Compute.VirtualMachine, id: receiver_vm.id)
      assert unchanged.desired_state == :paused
      resumed = Ledger.update!(unchanged, :request_start, %{generation: unchanged.generation + 1})
      Ledger.update!(resumed, :observe, %{observed_state: :running})
      [receiver] = Ledger.read!(Marshall.Agents.ThreadReceiver)
      Ledger.update!(receiver, :defer, %{next_attempt_at: nil})
    end

    if permission_revoked do
      assert {:ok, _} =
               Marshall.Threads.set_access(
                 %{
                   thread_id: thread.id,
                   email: to_string(subscriber.email),
                   role: :revoked,
                   idempotency_key: Ash.UUID.generate()
                 },
                 actor: actor
               )

      assert {:ok, _} = Marshall.Agents.ThreadDelivery.deliver_one()
      assert [] = Ledger.read!(Marshall.Agents.Turn, thread_id: receiver_thread.id)
      assert [%{state: :inactive, cursor: 0}] = Ledger.read!(Marshall.Agents.ThreadReceiver)

      assert {:ok, _} =
               Marshall.Threads.set_access(
                 %{
                   thread_id: thread.id,
                   email: to_string(subscriber.email),
                   role: :viewer,
                   idempotency_key: Ash.UUID.generate()
                 },
                 actor: actor
               )

      assert {:ok, _} =
               Ledger.transaction(fn ->
                 Marshall.Agents.ThreadDelivery.register(command, subscriber.id, thread.id, true)
               end)
    end

    if audit_failure do
      assert {:error, _} =
               Marshall.Repo.transaction(
                 fn ->
                   Ecto.Adapters.SQL.query!(
                     Marshall.Repo,
                     """
                     CREATE FUNCTION pg_temp.reject_delivery_receipt() RETURNS trigger LANGUAGE plpgsql AS
                     $$ BEGIN RAISE EXCEPTION 'injected delivery receipt failure'; END $$
                     """,
                     [], log: false)

                   Ecto.Adapters.SQL.query!(
                     Marshall.Repo,
                     """
                     CREATE TRIGGER reject_delivery_receipt BEFORE INSERT ON agent_audit_events
                     FOR EACH ROW WHEN (NEW.kind = 'maintenance_admitted')
                     EXECUTE FUNCTION pg_temp.reject_delivery_receipt()
                     """,
                     [], log: false)

                   Marshall.Agents.ThreadDelivery.deliver_one()
                 end,
                 mode: :savepoint
               )

      assert [] = Ledger.read!(Marshall.Agents.Turn, thread_id: receiver_thread.id)
      assert [] = Ledger.read!(Marshall.Agents.Event, thread_id: receiver_thread.id)
      assert [%{cursor: 0}] = Ledger.read!(Marshall.Agents.ThreadReceiver)
    end

    for _ <- 1..delivery_attempts,
        do: assert({:ok, _} = Marshall.Agents.ThreadDelivery.deliver_one())

    [delivered] = Ledger.read!(Marshall.Agents.Turn, thread_id: receiver_thread.id)
    assert delivered.maintenance_kind == :subscription_notification
    assert is_nil(delivered.prompt)
    assert delivered.maintenance_metadata["thread_id"] == thread.id

    assert [%{kind: :subscription_notification}] =
             Ledger.read!(Marshall.Agents.Event, thread_id: receiver_thread.id)

    assert [%{cursor: 1}] = Ledger.read!(Marshall.Agents.ThreadReceiver)

    assert [%{kind: :maintenance_admitted, outcome: :accepted}] =
             Ledger.read!(Marshall.Agents.AuditEvent, target_id: delivered.id)

    assert {:error, :forbidden} =
             MessageBoards.post!(actor.id, :standard, "late", "body", vm_id: vm.id)
  end
end
