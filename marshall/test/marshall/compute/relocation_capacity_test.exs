defmodule Marshall.Compute.RelocationCapacityTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Accounts.AdminEvent
  alias Marshall.Compute

  alias Marshall.Compute.{
    Host,
    Ledger,
    Operation,
    Relocation,
    RelocationCapacity,
    Reservation,
    TransferSlot,
    VirtualMachine,
    WorkloadPlacement
  }

  setup context do
    source = host_fixture(if context[:missing_source], do: %{transfer_endpoint: nil}, else: %{})
    owner = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    Ledger.update!(operation, :complete, %{})
    vm = Ledger.update!(vm, :observe, %{observed_state: :running})

    destination =
      host_fixture(if context[:missing_destination], do: %{transfer_endpoint: nil}, else: %{})

    %{source: source, destination: destination, vm: vm, owner: owner}
  end

  test "public relocation selects automatically and replays without new holds or jobs", c do
    request = %{vm_id: c.vm.id, idempotency_key: Ash.UUID.generate()}
    assert {:ok, relocation} = Compute.relocate(request, actor: c.owner)
    assert relocation.destination_host_id == c.destination.host.id
    assert relocation.source_placement_id == c.vm.current_placement_id
    jobs = Marshall.Repo.all(Oban.Job)

    for worker <- [
          "Marshall.Compute.Workers.PrepareRelocationKey",
          "Marshall.Compute.Workers.CoordinateRelocation"
        ] do
      assert Enum.any?(jobs, &(&1.worker == worker))
    end

    assert {:ok, retry} = Compute.relocate(request, actor: c.owner)
    assert retry.id == relocation.id
    assert length(Marshall.Repo.all(Oban.Job)) == length(jobs)
    assert length(Ledger.read!(TransferSlot)) == 2
    assert length(Ledger.read!(WorkloadPlacement, vm_id: c.vm.id)) == 2

    assert {:error, error} =
             Compute.relocate(%{request | idempotency_key: Ash.UUID.generate()}, actor: c.owner)

    assert Exception.message(error) =~ "relocation_in_progress"
    assert {:ok, _} = Compute.cancel_relocation(%{relocation_id: relocation.id}, actor: c.owner)
    assert {:ok, replay} = Compute.relocate(request, actor: c.owner)
    assert replay.id == relocation.id and replay.cancellation_requested_at != nil
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

    assert vm.current_placement_id == c.vm.current_placement_id and
             vm.generation == c.vm.generation
  end

  test "relocation admission diagnostics cover both outcomes", c do
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    request = %{vm_id: c.vm.id, idempotency_key: Ash.UUID.generate()}

    {{:ok, relocation}, admitted} =
      ExUnit.CaptureLog.with_log(
        [metadata: [:event, :vm_id, :relocation_id, :host_id]],
        fn -> Compute.relocate(request, actor: c.owner) end
      )

    assert admitted =~ "Relocation admitted"
    assert admitted =~ "event=relocation.admitted"
    assert admitted =~ "vm_id=" <> c.vm.id
    assert admitted =~ "relocation_id=" <> relocation.id
    assert admitted =~ "host_id=" <> relocation.destination_host_id

    refused =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :vm_id, :reason]], fn ->
        assert {:error, _} =
                 Compute.relocate(%{request | idempotency_key: Ash.UUID.generate()},
                   actor: c.owner
                 )
      end)

    assert refused =~ "Relocation admission refused"
    assert refused =~ "event=relocation.admission_refused"
    assert refused =~ "vm_id=" <> c.vm.id
    assert refused =~ "reason=relocation_in_progress"
  end

  test "administrator relocation is audited once and replay is idempotent", c do
    admin =
      Ledger.update!(c.owner, :assign_administrator, %{administrator: true})
      |> Marshall.PasskeyFixture.verified_session()

    request = %{vm_id: c.vm.id, idempotency_key: Ash.UUID.generate()}

    assert {:ok, relocation} = Compute.relocate(request, actor: admin)
    assert {:ok, replay} = Compute.relocate(request, actor: admin)
    assert replay.id == relocation.id

    assert [%{kind: :vm_relocate, actor_id: actor_id, target_id: target_id}] =
             Ledger.read!(AdminEvent, target_id: c.vm.id)

    assert actor_id == admin.id
    assert target_id == c.vm.id
  end

  test "public relocation requires current manage permission even on exact retries", c do
    member = user()
    request = %{vm_id: c.vm.id, idempotency_key: Ash.UUID.generate()}
    assert {:error, _} = Compute.relocate(request)
    assert {:error, _} = Compute.relocate(request, actor: member)
    assert_no_relocation(c)

    for role <- [:viewer, :operator] do
      assert {:ok, _} =
               Marshall.Access.set_access(
                 %{
                   vm_id: c.vm.id,
                   email: to_string(member.email),
                   role: role,
                   idempotency_key: Ash.UUID.generate()
                 },
                 actor: c.owner
               )

      assert {:error, _} = Compute.relocate(request, actor: member)
      assert_no_relocation(c)
    end

    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: c.vm.id,
                 email: to_string(member.email),
                 role: :manager,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    assert {:ok, relocation} = Compute.relocate(request, actor: member)
    assert relocation.requested_by_id == member.id

    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: c.vm.id,
                 email: to_string(member.email),
                 role: :revoked,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    assert {:error, _} = Compute.relocate(request, actor: member)
    assert length(Ledger.read!(Relocation, vm_id: c.vm.id)) == 1
  end

  @tag missing_destination: true
  test "public capacity rejection leaves no relocation placement, slots or jobs", c do
    before_jobs = length(Marshall.Repo.all(Oban.Job))

    assert {:error, error} =
             Compute.relocate(%{vm_id: c.vm.id, idempotency_key: Ash.UUID.generate()},
               actor: c.owner
             )

    assert Exception.message(error) =~ "insufficient_capacity"
    assert_no_relocation(c)
    assert length(Marshall.Repo.all(Oban.Job)) == before_jobs
  end

  @tag missing_source: true
  test "an unenrolled SSH source cannot reserve a relocation", context do
    assert {:error, :source_unavailable} = reserve(context)
    assert_no_relocation(context)
  end

  @tag missing_destination: true
  test "capacity alone cannot select an unenrolled SSH destination", context do
    assert {:error, :insufficient_capacity} = reserve(context)
    assert_no_relocation(context)
  end

  defp assert_no_relocation(context) do
    assert Ledger.read!(Relocation, vm_id: context.vm.id) == []
    assert Ledger.read!(TransferSlot) == []
    assert length(Ledger.read!(WorkloadPlacement, vm_id: context.vm.id)) == 1
  end

  test "a stopped-copy reservation holds both endpoints without changing source authority",
       context do
    key = Ash.UUID.generate()
    assert {:ok, relocation} = reserve(context, key)
    assert relocation.phase == :preparing
    assert relocation.destination_host_id == context.destination.host.id
    assert {:ok, retry} = reserve(context, key)
    assert retry.id == relocation.id
    assert length(Ledger.read!(WorkloadPlacement, vm_id: context.vm.id)) == 2
    assert length(Ledger.read!(TransferSlot)) == 2
    assert length(Ledger.read!(Relocation, vm_id: context.vm.id)) == 1

    # ADR-0155: one stopped full copy needs no temporary headroom on either endpoint.
    for reservation <- Ledger.read!(Reservation, vm_id: context.vm.id) do
      assert reservation.compute_held
      assert reservation.disk_held
      assert reservation.temporary_disk_bytes == 0
    end

    assert [vm] = Ledger.read!(VirtualMachine, id: context.vm.id)
    assert vm.current_placement_id == context.vm.current_placement_id
    assert vm.execution_epoch == context.vm.execution_epoch
    assert vm.generation == context.vm.generation
    assert vm.desired_state == :running
    assert {:error, :relocation_in_progress} = reserve(context)
  end

  test "logical guest disk cap does not consume physical snapshot headroom", context do
    # Enroll a destination whose entire logical allowance is exactly this disk.
    Ledger.update!(context.destination.host, :configure, %{enabled: false})

    destination =
      host_fixture()

    assert {:ok, relocation} = reserve(context)
    assert relocation.destination_host_id == destination.host.id
  end

  test "a destination with room for disk and both checkpoints accepts and waits for a probe",
       context do
    Ledger.update!(context.destination.pool, :report, %{
      free_bytes:
        context.destination.pool.overhead_bytes +
          OverallsProtocol.VMShape.reservation(context.vm).disk_bytes +
          2 * OverallsProtocol.VMShape.checkpoint_bytes(context.vm.memory_bytes),
      reported_at: Ledger.now()
    })

    assert {:ok, relocation} = reserve(context)
    assert relocation.destination_host_id == context.destination.host.id
    # No fresh connectivity probe: the running source MUST NOT be stopped.
    assert {:ok, :waiting} = Marshall.Compute.RelocationCoordinator.advance(relocation.id)
    assert [%{source_stop_operation_id: nil}] = Ledger.read!(Relocation, id: relocation.id)

    assert Enum.all?(
             Ledger.read!(Reservation, vm_id: context.vm.id),
             &(&1.temporary_disk_bytes == 0 and &1.compute_held and &1.disk_held)
           )
  end

  test "a destination without room for one whole disk is refused", context do
    Ledger.update!(context.destination.pool, :report, %{
      free_bytes:
        context.destination.pool.overhead_bytes +
          OverallsProtocol.VMShape.reservation(context.vm).disk_bytes - 1,
      reported_at: Ledger.now()
    })

    assert {:error, :insufficient_capacity} = reserve(context)
    assert_unchanged(context)
  end

  test "a running source must reserve both checkpoint slots before relocation", context do
    Ledger.update!(context.source.pool, :report, %{
      free_bytes: context.source.pool.overhead_bytes,
      reported_at: Ledger.now()
    })

    assert {:error, :insufficient_capacity} = reserve(context)

    assert [%{temporary_disk_bytes: 0, checkpoint_bytes: 0}] =
             Ledger.read!(Reservation, placement_id: context.vm.current_placement_id)
  end

  test "the first fitting destination in host UUID order is chosen", context do
    other = host_fixture()
    expected = Enum.min_by([context.destination.host, other.host], & &1.id)
    assert {:ok, relocation} = reserve(context)
    assert relocation.destination_host_id == expected.id
  end

  test "stopped workloads reserve disk but no compute even on a compute-full destination",
       context do
    Ledger.intent!(context.vm, %{desired_state: :stopped})
    Ledger.update!(context.vm, :observe, %{observed_state: :stopped})
    [source] = Ledger.read!(Reservation, placement_id: context.vm.current_placement_id)
    Ledger.update!(source, :release_compute, %{})

    Ledger.update!(context.destination.host, :report, %{
      effective_cores: 0,
      effective_memory_bytes: 0
    })

    assert {:ok, relocation} = reserve(context)
    assert relocation.original_state == :stopped

    assert Enum.all?(
             Ledger.read!(Reservation, vm_id: context.vm.id),
             &(not &1.compute_held and &1.disk_held and &1.temporary_disk_bytes == 0)
           )
  end

  test "another workload cannot reserve a host already sending or receiving", context do
    assert {:ok, _} = reserve(context)
    {:ok, other} = Compute.provision(request(), actor: context.owner)
    [operation] = Ledger.read!(Operation, vm_id: other.id)
    Ledger.update!(operation, :complete, %{})
    other = Ledger.update!(other, :observe, %{observed_state: :running})
    assert {:error, :transfer_busy} = reserve(%{context | vm: other})
    assert length(Ledger.read!(TransferSlot)) == 2
    assert [_] = Ledger.read!(WorkloadPlacement, vm_id: other.id)
    assert [%{temporary_disk_bytes: 0}] = Ledger.read!(Reservation, vm_id: other.id)
  end

  test "a running workload cannot overbook destination compute", context do
    Ledger.update!(context.destination.host, :report, %{capacity: capacity(0)})
    assert {:error, :insufficient_capacity} = reserve(context)
    assert_unchanged(context)
  end

  test "destination does not need the existing workload's image catalog entry", context do
    Ledger.update!(context.destination.host, :report, %{
      inventory: Map.put(context.destination.report.inventory, "images", [])
    })

    assert {:ok, relocation} = reserve(context)
    assert relocation.destination_host_id == context.destination.host.id
  end

  test "unreachable source is not relocation or disaster recovery", context do
    Ledger.update!(context.source.host, :disconnect, %{reported_at: nil})
    assert {:error, :source_unavailable} = reserve(context)
    assert_unchanged(context)
  end

  test "stale destination pools cannot receive reservations", context do
    Ledger.update!(context.destination.pool, :report, %{reported_at: nil})
    assert {:error, :insufficient_capacity} = reserve(context)
    assert_unchanged(context)
  end

  test "changed intent and insufficient management permission prevent preparation", context do
    stranger = user()
    assert {:error, _} = reserve(%{context | owner: stranger})
    Ledger.intent!(context.vm, %{desired_state: :stopped})
    assert {:error, :workload_not_stable} = reserve(context)
    assert_unchanged(context)
  end

  test "late record validation failure rolls back placement, both holds and slots", context do
    assert_raise Ash.Error.Invalid, fn -> reserve(context, "") end
    assert_unchanged(context)
  end

  defp reserve(context, key \\ Ash.UUID.generate()) do
    Ledger.transaction(fn ->
      hosts =
        Host
        |> Ledger.read!()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(&Ledger.lock!(Host, &1.id))

      vm = Ledger.lock!(VirtualMachine, context.vm.id)
      RelocationCapacity.reserve_locked!(vm, hosts, context.owner, key)
    end)
  end

  defp assert_unchanged(context) do
    assert [_] = Ledger.read!(WorkloadPlacement, vm_id: context.vm.id)
    assert [%{temporary_disk_bytes: 0}] = Ledger.read!(Reservation, vm_id: context.vm.id)
    assert Ledger.read!(Relocation, vm_id: context.vm.id) == []
    assert Ledger.read!(TransferSlot) == []
  end
end
