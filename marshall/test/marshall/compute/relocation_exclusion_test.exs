defmodule Marshall.Compute.RelocationExclusionTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Compute

  alias Marshall.Compute.{
    Drains,
    Host,
    HostDrain,
    Ledger,
    NetworkAddress,
    Operation,
    Outcomes,
    RelocationCapacity,
    Reservation,
    VirtualMachine
  }

  setup do
    source = host_fixture()
    owner = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    [original] = Ledger.read!(Operation, vm_id: vm.id)
    {:ok, _} = ingest(source.host.id, event(original, 1, :running))
    destination = host_fixture()
    %{source: source, destination: destination, owner: owner, vm: vm, original: original}
  end

  test "start and stop remain excluded while Delete supersedes a prepared move", c do
    {:ok, relocation} = prepare(c)

    for kind <- [:start, :stop] do
      assert {:error, error} = lifecycle(c, kind)
      assert Exception.message(error) =~ "relocation_in_progress"
    end

    assert [operation] = Ledger.read!(Operation, vm_id: c.vm.id)
    assert operation.id == c.original.id
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    assert vm.generation == c.vm.generation
    assert vm.desired_state == :running
    assert vm.current_placement_id == c.vm.current_placement_id

    holds = Ledger.read!(Reservation, vm_id: vm.id) |> Enum.sort_by(& &1.id)
    assert {:ok, deletion} = lifecycle(c, :delete)
    assert deletion.generation == vm.generation + 1
    assert deletion.placement_id == vm.current_placement_id

    assert [%{deletion_operation_id: id, cancellation_requested_at: requested}] =
             Ledger.read!(Marshall.Compute.Relocation, id: relocation.id)

    assert id == deletion.id and requested != nil
    assert holds == Ledger.read!(Reservation, vm_id: vm.id) |> Enum.sort_by(& &1.id)
  end

  test "an exact lifecycle retry returns its prior operation without disturbing relocation", c do
    key = Ash.UUID.generate()
    {:ok, original} = lifecycle(c, :start, key)
    {:ok, _} = ingest(c.source.host.id, event(original, 2, :running))
    {:ok, _} = prepare(c)
    assert {:ok, repeated} = lifecycle(c, :start, key)
    assert repeated.id == original.id
    assert length(Ledger.read!(Operation, vm_id: c.vm.id)) == 2
  end

  test "crash and startup failure evidence cannot restart or release a relocating source", c do
    {:ok, _} = prepare(c)

    for {reason, sequence} <- [{:crashed, 2}, {:execution_failed, 3}] do
      assert {:ok, _} = ingest(c.source.host.id, event(c.original, sequence, :failed, reason))

      assert [%{generation: 1, observed_state: :failed, crash_restart_times: []}] =
               Ledger.read!(VirtualMachine, id: c.vm.id)

      assert [_] = Ledger.read!(Operation, vm_id: c.vm.id)

      assert Enum.all?(
               Ledger.read!(Reservation, vm_id: c.vm.id),
               &(&1.compute_held and &1.disk_held and &1.temporary_disk_bytes == 0)
             )
    end
  end

  test "a source stop during relocation retains compute for precommit cancellation", c do
    {:ok, _} = prepare(c)
    # Simulate the coordinator's source-stop intent; ordinary lifecycle is excluded.
    {:ok, stop} =
      Ledger.transaction(fn ->
        Ledger.lock!(Host, c.source.host.id)
        vm = Ledger.lock!(VirtualMachine, c.vm.id)

        vm =
          Ledger.intent!(vm, %{
            generation: vm.generation + 1,
            desired_state: :stopped
          })

        Ledger.create!(Operation, :enqueue, %{
          vm_id: vm.id,
          placement_id: vm.current_placement_id,
          execution_epoch: vm.execution_epoch,
          generation: vm.generation,
          kind: :stop,
          requested_by_id: c.owner.id
        })
      end)

    assert {:ok, _} = ingest(c.source.host.id, event(stop, 2, :stopped))
    assert [%{observed_state: :stopped}] = Ledger.read!(VirtualMachine, id: c.vm.id)

    assert [%{compute_held: true, disk_held: true}] =
             Ledger.read!(Reservation, placement_id: c.vm.current_placement_id)

    assert [%{status: :completed}] = Ledger.read!(Operation, id: stop.id)
  end

  test "stream completion does not permit maintenance during readiness or cleanup", c do
    {:ok, relocation} = prepare(c)
    release_slots(relocation)

    for host <- [c.source.host, c.destination.host] do
      assert {:error, :relocation_in_progress} =
               Drains.request(host.id, Ash.UUID.generate(), "relocation-test")

      assert [%{maintenance_mode: :normal, enabled: true}] = Ledger.read!(Host, id: host.id)
      assert Ledger.read!(HostDrain, host_id: host.id) == []
    end
  end

  test "a delayed drain cannot declare a transfer-only destination quiescent", c do
    {:ok, relocation} = prepare(c)
    release_slots(relocation)

    for reservation <- Ledger.read!(Reservation, vm_id: c.vm.id),
        do: Ledger.update!(reservation, :release_compute, %{})

    # Simulate an already recorded drain arriving after the relocation was prepared.
    Ledger.update!(c.destination.host, :maintenance, %{
      maintenance_mode: :draining,
      enabled: false
    })

    drain =
      Ledger.create!(HostDrain, :request, %{
        host_id: c.destination.host.id,
        operator_reference: "delayed-test"
      })

    assert {:ok, 0} = Drains.advance(drain.id)
    assert {:ok, %{status: "draining", currently_quiescent: false}} = Drains.status(drain.id)
  end

  test "a delete outcome retains the address until every copy has been reclaimed", c do
    {:ok, relocation} = prepare(c)
    release_slots(relocation)
    # Simulate retained data after an incorrectly/previously finished coordinator;
    # this regression deliberately does not rely on the active-relocation guard.
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE compute_relocations SET finished_at = clock_timestamp() WHERE id = $1",
      [Ecto.UUID.dump!(relocation.id)]
    )

    {:ok, delete} = lifecycle(c, :delete)
    assert {:ok, _} = ingest(c.source.host.id, event(delete, 2, :deleted))

    assert [%{archived_at: nil, desired_state: :deleted}] =
             Ledger.history!(VirtualMachine, id: c.vm.id)

    assert [_] = Ledger.read!(NetworkAddress, vm_id: c.vm.id)

    assert [%{disk_held: true}] =
             Ledger.read!(Reservation, placement_id: relocation.destination_placement_id)

    # Database-only simulation of destination reclamation, not physical acceptance.
    Ledger.transaction(fn ->
      Ledger.lock!(Host, c.destination.host.id)
      Ledger.lock!(VirtualMachine, c.vm.id)
      [destination] = Ledger.read!(Reservation, placement_id: relocation.destination_placement_id)
      Ledger.update!(destination, :release_all, %{})
    end)

    assert {:ok, _} = ingest(c.source.host.id, event(delete, 3, :deleted))
    assert [%{archived_at: archived}] = Ledger.history!(VirtualMachine, id: c.vm.id)
    refute is_nil(archived)
    assert Ledger.read!(NetworkAddress, vm_id: c.vm.id) == []
  end

  defp prepare(c) do
    Ledger.transaction(fn ->
      hosts =
        Host |> Ledger.read!() |> Enum.sort_by(& &1.id) |> Enum.map(&Ledger.lock!(Host, &1.id))

      vm = Ledger.lock!(VirtualMachine, c.vm.id)
      RelocationCapacity.reserve_locked!(vm, hosts, c.owner, Ash.UUID.generate())
    end)
  end

  defp release_slots(relocation) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      UPDATE compute_transfer_slots SET released_at = clock_timestamp()
      WHERE source_relocation_id = $1 OR destination_relocation_id = $1
      """,
      [Ecto.UUID.dump!(relocation.id)]
    )
  end

  defp lifecycle(c, kind, key \\ Ash.UUID.generate()),
    do: Compute.lifecycle(%{vm_id: c.vm.id, kind: kind, idempotency_key: key}, actor: c.owner)

  defp ingest(host, event) do
    {:ok, event} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    Ledger.transaction(fn ->
      Ledger.lock!(Host, host)
      Outcomes.ingest_locked!(host, [event])
    end)
  end

  defp event(operation, sequence, state, reason \\ :none),
    do: %{
      id: Ash.UUID.generate(),
      vm_id: operation.vm_id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: sequence,
      state: state,
      compute_empty: state in [:stopped, :failed, :deleted],
      disk_present: state != :deleted,
      cleanup_complete: state == :deleted,
      reason: reason
    }
end
