defmodule Marshall.Compute.UsageAdmissionTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Compute

  alias Marshall.Compute.{
    Host,
    HostReports,
    Ledger,
    Operation,
    Outcomes,
    Reservation,
    VirtualMachine
  }

  setup do
    Map.put(host_fixture(), :actor, user())
  end

  test "settled low usage allows CPU, memory and disk promises beyond physical limits", c do
    Enum.reduce(1..10, %{}, fn sequence, allocations ->
      assert {:ok, vm} = Compute.provision(request(), actor: c.actor)
      [operation] = Ledger.read!(Operation, vm_id: vm.id)
      event = outcome(operation, :running)
      allocations = Map.put(allocations, vm.current_placement_id, 1_048_576)
      report = report_for(c, sequence + 1, allocations, event)
      assert {:ok, :ok} = ingest(c, event, report)
      [held] = Ledger.read!(Reservation, vm_id: vm.id)
      assert held.compute_held and held.disk_held
      refute held.startup_compute_held or held.startup_disk_held
      allocations
    end)

    held = Ledger.read!(Reservation, host_id: c.host.id)
    assert Enum.sum(Enum.map(held, & &1.vcpu)) > c.report.effective_cores
    assert Enum.sum(Enum.map(held, & &1.memory_bytes)) > c.report.effective_memory_bytes
    assert Enum.sum(Enum.map(held, & &1.disk_bytes)) > hd(c.report.pools).total_bytes
  end

  test "unrecorded and stale generation proofs cannot settle a new startup", c do
    {:ok, vm} = Compute.provision(request(), actor: c.actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    event = outcome(operation, :running)
    report = report_for(c, 2, %{vm.current_placement_id => 0}, event)
    assert {:ok, :ok} = HostReports.ingest(c.host.id, c.epoch, report)
    [held] = Ledger.read!(Reservation, vm_id: vm.id)
    assert held.startup_compute_held and held.startup_disk_held
    assert {:ok, :ok} = ingest(c, event, %{report | sequence: 3})

    assert {:ok, start} =
             Compute.lifecycle(
               %{vm_id: vm.id, kind: :start, idempotency_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert start.generation > event.generation
    assert {:ok, :ok} = HostReports.ingest(c.host.id, c.epoch, %{report | sequence: 4})
    [held] = Ledger.read!(Reservation, vm_id: vm.id)
    assert held.startup_compute_held
    refute held.startup_disk_held
  end

  test "unknown and saturated telemetry reject new work and automatic recovery retains the disk",
       c do
    {:ok, vm} = Compute.provision(request(), actor: c.actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)

    for {usage, seq} <- [{nil, 2}, {capacity(0, 0), 3}] do
      assert {:ok, :ok} =
               HostReports.ingest(c.host.id, c.epoch, %{c.report | sequence: seq, capacity: usage})

      assert {:error, _} = Compute.provision(request(), actor: c.actor)

      assert {:error, _} =
               Compute.lifecycle(
                 %{vm_id: vm.id, kind: :start, idempotency_key: Ash.UUID.generate()},
                 actor: c.actor
               )
    end

    event = outcome(operation, :failed)

    assert {:ok, _} =
             Ledger.transaction(fn ->
               Ledger.lock!(Host, c.host.id)
               Outcomes.ingest_locked!(c.host.id, [event])
             end)

    [held] = Ledger.read!(Reservation, vm_id: vm.id)
    refute held.compute_held
    assert held.disk_held
    assert length(Ledger.read!(Operation, vm_id: vm.id)) == 1
    assert [%{observed_state: :failed}] = Ledger.read!(VirtualMachine, id: vm.id)
  end

  test "missing native allocation cannot settle disk even with a running proof", c do
    {:ok, vm} = Compute.provision(request(), actor: c.actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    event = outcome(operation, :running)
    assert {:ok, :ok} = ingest(c, event, report_for(c, 2, %{}, event))
    [held] = Ledger.read!(Reservation, vm_id: vm.id)
    refute held.startup_compute_held
    assert held.startup_disk_held
  end

  test "superseded physical evidence cannot settle even the same generation", c do
    {:ok, vm} = Compute.provision(request(), actor: c.actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    event = outcome(operation, :running)
    report = report_for(c, 2, %{vm.current_placement_id => 0}, event)
    newer = %{event | id: Ash.UUID.generate(), sequence: 2, state: :unknown, reason: :unknown}

    assert {:ok, :ok} =
             Ledger.transaction(fn ->
               host = Ledger.lock!(Host, c.host.id)
               Outcomes.ingest_locked!(host.id, [event, newer])
               HostReports.ingest_locked!(host, c.epoch, report)
             end)

    [held] = Ledger.read!(Reservation, vm_id: vm.id)
    assert held.startup_compute_held and held.startup_disk_held
  end

  test "operator margin reconciliation is idempotent and preserves ownership bindings", c do
    {:ok, vm} = Compute.provision(request(), actor: c.actor)
    before = Ledger.read!(Reservation, vm_id: vm.id)

    for _ <- 1..2,
        do: assert({:ok, :ok} = Marshall.Compute.CapacityPolicy.configure(c.host.id, 0, 0, 0))

    [host] = Ledger.read!(Host, id: c.host.id)
    [pool] = Ledger.read!(Marshall.Compute.StoragePool, id: c.pool.id)

    assert host.overhead_cores == 0 and host.overhead_memory_bytes == 0 and
             pool.overhead_bytes == 0

    assert Marshall.Compute.StoragePool.descriptor(pool) ==
             Marshall.Compute.StoragePool.descriptor(c.pool)

    assert Ledger.read!(Reservation, vm_id: vm.id) == before

    assert_raise Ash.Error.Forbidden, fn ->
      pool
      |> Ash.Changeset.for_update(:configure_overhead, %{overhead_bytes: 100}, actor: c.actor)
      |> Ash.update!(actor: c.actor)
    end
  end

  defp ingest(c, event, report) do
    Ledger.transaction(fn ->
      host = Ledger.lock!(Host, c.host.id)
      Outcomes.ingest_locked!(host.id, [event])
      HostReports.ingest_locked!(host, c.epoch, report)
    end)
  end

  defp report_for(c, sequence, allocations, event) do
    pool = hd(c.report.pools)
    free = pool.total_bytes - Enum.sum(Map.values(allocations))

    pool = %{
      pool
      | free_bytes: free,
        allocations: allocations,
        storage: storage_observation(c.pool, pool.total_bytes, free)
    }

    proof = %{
      "outcome_id" => event.id,
      "generation" => event.generation,
      "execution_epoch" => event.execution_epoch,
      "compute" => true,
      "disk" => true
    }

    %{
      c.report
      | sequence: sequence,
        sampled_at: Ledger.now(),
        pools: [pool],
        capacity: Map.put(capacity(), "covered", %{event.placement_id => proof})
    }
  end

  defp outcome(operation, state) do
    %{
      id: Ash.UUID.generate(),
      vm_id: operation.vm_id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: 1,
      state: state,
      compute_empty: state == :failed,
      disk_present: true,
      cleanup_complete: false,
      reason: if(state == :failed, do: :crashed, else: :none)
    }
  end
end
