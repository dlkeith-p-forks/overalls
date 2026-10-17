defmodule Marshall.Compute.WorkloadPlacementTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Compute
  alias Marshall.Compute.{Ledger, Reservation, VirtualMachine, WorkloadPlacement}

  setup do
    base = host_fixture()
    owner = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    Map.merge(base, %{owner: owner, vm: vm})
  end

  test "admission creates a distinct copy and returns placement-derived location", context do
    %{vm: vm, host: host, pool: pool} = context
    assert vm.id != vm.current_placement_id
    assert vm.execution_epoch == 1
    assert vm.host_id == host.id
    assert vm.pool_id == pool.id
    assert [placement] = Ledger.read!(WorkloadPlacement, vm_id: vm.id)
    assert placement.id == vm.current_placement_id
    assert {placement.host_id, placement.pool_id} == {host.id, pool.id}
    assert [reservation] = Ledger.read!(Reservation, placement_id: placement.id)
    assert reservation.vm_id == vm.id

    assert [%{id: id}] = Ledger.read!(VirtualMachine, host_id: host.id, pool_id: pool.id)
    assert id == vm.id

    # Force validation inside the sandbox instead of relying on its final rollback.
    assert {:ok, _} = Ecto.Adapters.SQL.query(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
  end

  test "another retained copy gets its own reservation without changing current authority",
       context do
    %{vm: vm, host: host, pool: pool} = context

    placement =
      Ledger.create!(WorkloadPlacement, :allocate, %{
        vm_id: vm.id,
        host_id: host.id,
        pool_id: pool.id
      })

    reservation =
      Ledger.create!(Reservation, :reserve, %{
        vm_id: vm.id,
        placement_id: placement.id,
        host_id: host.id,
        pool_id: pool.id,
        vcpu: vm.vcpu,
        memory_bytes: OverallsProtocol.VMShape.host_memory(vm.memory_bytes),
        disk_bytes: vm.disk_bytes
      })

    assert length(Ledger.read!(Reservation, vm_id: vm.id)) == 2
    assert [%{current_placement_id: current}] = Ledger.read!(VirtualMachine, id: vm.id)
    assert current == vm.current_placement_id
    refute current == placement.id
    Ledger.update!(reservation, :release_all, %{})
    assert [_] = Ledger.read!(WorkloadPlacement, id: placement.id)
  end

  test "the database rejects a placement on another host's pool", context do
    other = host_fixture()

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "INSERT INTO compute_workload_placements (vm_id, host_id, pool_id) VALUES ($1, $2, $3)",
               Enum.map([context.vm.id, context.host.id, other.pool.id], &Ecto.UUID.dump!/1)
             )
  end

  test "the database rejects reservation identity inconsistent with its placement", context do
    other = host_fixture()

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE compute_reservations SET host_id = $1, pool_id = $2 WHERE vm_id = $3",
               Enum.map([other.host.id, other.pool.id, context.vm.id], &Ecto.UUID.dump!/1)
             )
  end

  test "the database rejects another VM's placement as current authority", context do
    {:ok, other} = Compute.provision(request(), actor: context.owner)
    Ecto.Adapters.SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE compute_virtual_machines SET current_placement_id = $1 WHERE id = $2",
               Enum.map([other.current_placement_id, context.vm.id], &Ecto.UUID.dump!/1)
             )
  end

  test "ordinary users cannot allocate placements through an internal action", context do
    assert {:error, %Ash.Error.Forbidden{}} =
             WorkloadPlacement
             |> Ash.Changeset.for_create(
               :allocate,
               %{
                 vm_id: context.vm.id,
                 host_id: context.host.id,
                 pool_id: context.pool.id
               },
               actor: context.owner
             )
             |> Ash.create()
  end

  test "the database permits only one reservation per placement", context do
    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               INSERT INTO compute_reservations
                 (placement_id, vm_id, host_id, pool_id, vcpu, memory_bytes, disk_bytes)
               SELECT placement_id, vm_id, host_id, pool_id, vcpu, memory_bytes, disk_bytes
               FROM compute_reservations WHERE vm_id = $1
               """,
               [Ecto.UUID.dump!(context.vm.id)]
             )
  end
end
