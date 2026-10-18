defmodule Marshall.Access.PinsTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.{Access, Compute, Threads}
  alias Marshall.Access.{Pin, Pins}
  alias Marshall.Accounts.DeleteUserMachines
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes, VirtualMachine}

  setup do
    fixture = host_fixture()
    owner = user()
    member = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    %{owner: owner, member: member, vm: vm, fixture: fixture}
  end

  test "pinning is idempotent, reuses one live row and projects into the user's view", c do
    assert {:ok, %Pin{state: :pinned} = pin} =
             Access.pin_machine(%{vm_id: c.vm.id}, actor: c.owner)

    assert {:ok, %Pin{id: repeat_id, state: :pinned, pinned_at: repeat_at}} =
             Access.pin_machine(%{vm_id: c.vm.id}, actor: c.owner)

    assert {repeat_id, repeat_at} == {pin.id, pin.pinned_at}
    assert {:ok, %{pinned: true}} = Compute.get_vm(%{vm_id: c.vm.id}, actor: c.owner)
    assert Pins.pinned_vm_ids(c.owner) == [c.vm.id]
    assert {:ok, %{items: [%{id: id, pinned: true}]}} = Compute.pinned_vms(%{}, actor: c.owner)
    assert id == c.vm.id

    assert {:ok, %Pin{state: :unpinned, id: pin_id}} =
             Access.unpin_machine(%{vm_id: c.vm.id}, actor: c.owner)

    assert pin_id == pin.id
    assert {:ok, %Pin{state: :unpinned}} = Access.unpin_machine(%{vm_id: c.vm.id}, actor: c.owner)
    assert {:ok, %{pinned: false}} = Compute.get_vm(%{vm_id: c.vm.id}, actor: c.owner)
    assert {:ok, %{items: []}} = Compute.pinned_vms(%{}, actor: c.owner)

    assert {:ok, %Pin{state: :pinned, id: ^pin_id}} =
             Access.pin_machine(%{vm_id: c.vm.id}, actor: c.owner)

    assert [%Pin{}] = Ledger.read!(Pin, vm_id: c.vm.id, user_id: c.owner.id)
    assert Enum.any?(Ledger.read!(Pin.Version), &(&1.version_action_name == :repin))
  end

  test "pinning requires current read access, unpinning only a live row", c do
    assert {:error, error} = Access.pin_machine(%{vm_id: c.vm.id}, actor: c.member)
    assert Exception.message(error) =~ "forbidden"
    assert {:error, error} = Access.unpin_machine(%{vm_id: c.vm.id}, actor: c.member)
    assert Exception.message(error) =~ "forbidden"
    assert {:error, _} = Access.pin_machine(%{vm_id: Ash.UUID.generate()}, actor: c.member)

    grant = %{
      vm_id: c.vm.id,
      email: to_string(c.member.email),
      role: :viewer,
      idempotency_key: Ash.UUID.generate()
    }

    assert {:ok, _} = Access.set_access(grant, actor: c.owner)
    assert {:ok, %Pin{state: :pinned}} = Access.pin_machine(%{vm_id: c.vm.id}, actor: c.member)
    assert {:ok, %{items: [%{pinned: true}]}} = Compute.pinned_vms(%{}, actor: c.member)

    assert {:ok, _} =
             Access.set_access(%{grant | role: :revoked, idempotency_key: Ash.UUID.generate()},
               actor: c.owner
             )

    # Lost access hides the pin from the section but still lets the member clear it.
    assert {:ok, %{items: []}} = Compute.pinned_vms(%{}, actor: c.member)
    assert {:error, _} = Access.pin_machine(%{vm_id: c.vm.id}, actor: c.member)

    assert {:ok, %Pin{state: :unpinned}} =
             Access.unpin_machine(%{vm_id: c.vm.id}, actor: c.member)
  end

  test "a failed machine cannot gain a pin but keeps and can clear an existing one", c do
    {:ok, other} = Compute.provision(request(), actor: c.owner)
    assert {:ok, _} = Access.pin_machine(%{vm_id: other.id}, actor: c.owner)

    for vm <- [c.vm, other] do
      [current] = Ledger.read!(VirtualMachine, id: vm.id)
      Ledger.update!(current, :observe, %{observed_state: :failed})
    end

    assert {:error, error} = Access.pin_machine(%{vm_id: c.vm.id}, actor: c.owner)
    assert Exception.message(error) =~ "machine_failed"
    assert Ledger.read!(Pin, vm_id: c.vm.id) == []

    assert {:ok, %Pin{state: :pinned}} = Access.pin_machine(%{vm_id: other.id}, actor: c.owner)

    assert {:ok, %Pin{state: :unpinned}} =
             Access.unpin_machine(%{vm_id: other.id}, actor: c.owner)

    assert {:error, error} = Access.pin_machine(%{vm_id: other.id}, actor: c.owner)
    assert Exception.message(error) =~ "machine_failed"
  end

  test "a deleting machine cannot be pinned and the cap refuses a 21st pin", c do
    # Each synthetic host admits two of these machines.
    for _ <- 1..10, do: host_fixture()

    vms =
      for _ <- 1..Pins.limit() do
        {:ok, vm} = Compute.provision(request(), actor: c.owner)
        vm
      end

    for vm <- vms, do: assert({:ok, _} = Access.pin_machine(%{vm_id: vm.id}, actor: c.owner))
    assert {:error, error} = Access.pin_machine(%{vm_id: c.vm.id}, actor: c.owner)
    assert Exception.message(error) =~ "pin_limit"
    assert length(Pins.pinned_vm_ids(c.owner)) == Pins.limit()

    # A repeat of an already pinned machine is not a new pin.
    assert {:ok, _} = Access.pin_machine(%{vm_id: hd(vms).id}, actor: c.owner)
    assert {:ok, _} = Access.unpin_machine(%{vm_id: hd(vms).id}, actor: c.owner)
    assert {:ok, _} = Access.pin_machine(%{vm_id: c.vm.id}, actor: c.owner)
    assert {:ok, _} = Access.unpin_machine(%{vm_id: c.vm.id}, actor: c.owner)

    {:ok, _} = lifecycle(c.vm, c.owner, :delete)
    assert {:error, error} = Access.pin_machine(%{vm_id: c.vm.id}, actor: c.owner)
    assert Exception.message(error) =~ "vm_deleted"
  end

  test "the owner's pin blocks every lifecycle delete path, other users' pins do not", c do
    admin = Marshall.PasskeyFixture.verified_session(Marshall.PasskeyFixture.user(true))

    grant = %{
      vm_id: c.vm.id,
      email: to_string(c.member.email),
      role: :manager,
      idempotency_key: Ash.UUID.generate()
    }

    assert {:ok, _} = Access.set_access(grant, actor: c.owner)
    assert {:ok, _} = Access.pin_machine(%{vm_id: c.vm.id}, actor: c.member)

    # A manager's pin never fences the owner, a manager or an administrator.
    assert {:ok, _} = lifecycle(c.vm, c.owner, :stop)
    refute Pins.owner_pinned?(c.vm)

    assert {:ok, _} = Access.pin_machine(%{vm_id: c.vm.id}, actor: c.owner)
    assert Pins.owner_pinned?(c.vm)

    for actor <- [c.owner, c.member, admin] do
      assert {:error, error} = lifecycle(c.vm, actor, :delete)
      assert Exception.message(error) =~ "machine_pinned"
    end

    assert [%{desired_state: :stopped}] = Ledger.read!(VirtualMachine, id: c.vm.id)
    assert [] = Enum.filter(Ledger.read!(Operation, vm_id: c.vm.id), &(&1.kind == :delete))

    # Start and stop are unaffected by the pin.
    assert {:ok, _} = lifecycle(c.vm, c.owner, :start)

    assert {:ok, _} = Access.unpin_machine(%{vm_id: c.vm.id}, actor: c.owner)
    assert {:ok, delete} = lifecycle(c.vm, c.member, :delete)
    assert delete.kind == :delete

    # The manager's pin is still live until the archive removes it.
    assert [%Pin{state: :pinned}] = Ledger.read!(Pin, vm_id: c.vm.id, user_id: c.member.id)
    assert {:ok, _} = ingest(c.vm.host_id, outcome(delete, 1, :deleted))
    assert [] = Ledger.read!(Pin, vm_id: c.vm.id)
    assert length(Ledger.history!(Pin, vm_id: c.vm.id)) == 2
    assert Enum.all?(Ledger.history!(Pin, vm_id: c.vm.id), &(&1.archived_at != nil))
    assert [] = Ledger.read!(VirtualMachine, id: c.vm.id)
  end

  test "the refusal is logged through the catalog after rollback", c do
    assert {:ok, _} = Access.pin_machine(%{vm_id: c.vm.id}, actor: c.owner)
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    refused =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :vm_id, :reason]], fn ->
        assert {:error, _} = lifecycle(c.vm, c.owner, :delete)
      end)

    assert refused =~ "event=vm.lifecycle_refused"
    assert refused =~ "reason=machine_pinned"

    pinned =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :vm_id]], fn ->
        assert {:ok, _} = Access.unpin_machine(%{vm_id: c.vm.id}, actor: c.owner)
        assert {:ok, _} = Access.unpin_machine(%{vm_id: c.vm.id}, actor: c.owner)
      end)

    assert pinned =~ "event=vm.unpinned"
    assert length(Regex.scan(~r/event=vm\.unpinned/, pinned)) == 1

    refused =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :vm_id, :reason]], fn ->
        assert {:error, _} = Access.pin_machine(%{vm_id: c.vm.id}, actor: c.member)
      end)

    assert refused =~ "event=vm.pin_refused"
    assert refused =~ "reason=forbidden"
  end

  test "account deletion proceeds past the departing owner's pins and archives them" do
    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap)
    Ledger.update!(bootstrap, :complete, %{})
    admin = Marshall.PasskeyFixture.verified_session(Marshall.PasskeyFixture.user(true))
    user = Marshall.PasskeyFixture.user()
    host_fixture()
    {:ok, owned} = Compute.provision(request(), actor: user)
    {:ok, other} = Compute.provision(request(), actor: admin)

    assert {:ok, _} =
             Access.set_access(
               %{
                 vm_id: other.id,
                 email: to_string(user.email),
                 role: :viewer,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: admin
             )

    assert {:ok, _} = Access.pin_machine(%{vm_id: owned.id}, actor: user)
    assert {:ok, _} = Access.pin_machine(%{vm_id: other.id}, actor: user)
    assert {:ok, _} = Access.pin_machine(%{vm_id: other.id}, actor: admin)

    {:ok, deletion} =
      Marshall.Accounts.User
      |> Ash.ActionInput.for_action(
        :delete_user,
        %{user_id: user.id, confirmation: to_string(user.email)},
        actor: admin
      )
      |> Ash.run_action()

    assert {:ok, %{complete: false, remaining: 1}} =
             DeleteUserMachines.run(%{arguments: %{primary_key: %{"id" => deletion.id}}}, [], %{
               actor: SystemActor.compute()
             })

    assert [%{kind: :delete}] =
             Enum.filter(Ledger.read!(Operation, vm_id: owned.id), &(&1.kind == :delete))

    assert [] = Ledger.read!(Pin, user_id: user.id)
    assert [%Pin{state: :pinned}] = Ledger.read!(Pin, vm_id: other.id, user_id: admin.id)
    assert [%{desired_state: :running}] = Ledger.read!(VirtualMachine, id: other.id)
  end

  test "a pinned thread machine refuses thread deletion with the pin reason", c do
    {:ok, thread} =
      Threads.create_thread(
        %{
          objective: "Keep this one",
          mode: :medium,
          machine_spec: request(),
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.owner
      )

    assert {:snooze, _} =
             Threads.ProvisionWorker.perform(%Oban.Job{
               args: %{"thread_id" => thread.id, "machine_key" => thread.machine_key}
             })

    [bound] = Ledger.history!(Threads.Thread, id: thread.id)
    assert {:ok, _} = Access.pin_machine(%{vm_id: bound.machine_id}, actor: c.owner)
    assert {:error, error} = Threads.delete_thread(%{thread_id: thread.id}, actor: c.owner)
    assert Threads.error_reason(error) == :machine_pinned
    assert [%{desired_state: :running}] = Ledger.read!(VirtualMachine, id: bound.machine_id)
    assert {:ok, _} = Access.unpin_machine(%{vm_id: bound.machine_id}, actor: c.owner)

    assert {:ok, %{status: :deleting}} =
             Threads.delete_thread(%{thread_id: thread.id}, actor: c.owner)
  end

  defp lifecycle(vm, actor, kind),
    do:
      Compute.lifecycle(%{vm_id: vm.id, kind: kind, idempotency_key: Ash.UUID.generate()},
        actor: actor
      )

  defp ingest(host, event) do
    {:ok, event} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    Ledger.transaction(fn ->
      Ledger.lock!(Host, host)
      Outcomes.ingest_locked!(host, [event])
    end)
  end

  defp outcome(operation, sequence, state) do
    %{
      id: Ash.UUID.generate(),
      vm_id: operation.vm_id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: sequence,
      state: state,
      compute_empty: state in [:stopped, :deleted, :failed],
      disk_present: state != :deleted,
      cleanup_complete: state == :deleted,
      reason: :none
    }
  end
end
