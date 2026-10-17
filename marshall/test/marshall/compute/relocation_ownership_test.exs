defmodule Marshall.Compute.RelocationOwnershipTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Compute

  alias Marshall.Compute.{
    CloneRequest,
    Host,
    Ledger,
    Relocation,
    StoragePool,
    TransferSlot,
    TransferSlots,
    WorkloadPlacement
  }

  setup do
    relocation_fixture()
  end

  @spec relocation_fixture() :: map()
  defp relocation_fixture do
    _first_host = host_fixture()
    owner = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    destination = host_fixture()
    [current_placement] = Ledger.read!(WorkloadPlacement, id: vm.current_placement_id)
    [source_host] = Ledger.read!(Host, id: current_placement.host_id)
    [source_pool] = Ledger.read!(StoragePool, id: current_placement.pool_id)
    source = %{host: source_host, pool: source_pool}

    placement =
      Ledger.create!(WorkloadPlacement, :allocate, %{
        vm_id: vm.id,
        host_id: destination.host.id,
        pool_id: destination.pool.id
      })

    attributes = %{
      vm_id: vm.id,
      source_placement_id: vm.current_placement_id,
      destination_placement_id: placement.id,
      source_host_id: source.host.id,
      destination_host_id: destination.host.id,
      source_epoch: vm.execution_epoch,
      destination_epoch: vm.execution_epoch + 1,
      original_state: :running,
      requested_by_id: owner.id,
      request_key: Ash.UUID.generate()
    }

    relocation = Ledger.create!(Relocation, :record, attributes)

    %{
      source: source,
      destination: destination,
      vm: vm,
      owner: owner,
      attributes: attributes,
      relocation: relocation
    }
  end

  test "both endpoints are occupied and exact retries retain slot identities", context do
    assert {:ok, slots} = occupy(context.relocation)

    assert Enum.sort(Enum.map(slots, & &1.host_id)) ==
             Enum.sort([context.source.host.id, context.destination.host.id])

    assert {:ok, repeated} = occupy(context.relocation)
    assert Enum.map(repeated, & &1.id) == Enum.map(slots, & &1.id)
    assert length(Ledger.read!(TransferSlot)) == 2

    assert [%{current_placement_id: current, execution_epoch: 1}] =
             Ledger.read!(Compute.VirtualMachine, id: context.vm.id)

    assert current == context.vm.current_placement_id
  end

  # @cc [owner:ghuntley,label:verification;concurrency] generated-shared-transfer-slot
  # A clone and a relocation MUST NOT occupy one host simultaneously. A failed
  # paired relocation MUST leave neither new endpoint claimed; released rows
  # MUST stay historical while the previously blocked claimant can proceed.
  property "generated clone and relocation claims retain exclusive host slots" do
    check all(
            incumbent <- member_of([:clone, :relocation]),
            contested_endpoint <- member_of([:source, :destination]),
            retries <- integer(1..3),
            max_runs: 8
          ) do
      context = relocation_fixture()

      host_id =
        if contested_endpoint == :source,
          do: context.source.host.id,
          else: context.destination.host.id

      clone =
        Ledger.create!(CloneRequest, :enqueue, %{
          source_vm_id: context.vm.id,
          requested_by_id: context.owner.id,
          request_key: Ash.UUID.generate(),
          destination_vm_id: Ash.UUID.generate(),
          name: "clone-#{Ash.UUID.generate()}",
          sequence: System.unique_integer([:positive, :monotonic])
        })

      if incumbent == :clone do
        clone_slot =
          Ledger.create!(TransferSlot, :occupy, %{
            host_id: host_id,
            clone_request_id: clone.id
          })

        for _ <- 1..retries do
          assert {:error, :transfer_busy} = occupy(context.relocation)
          assert Enum.map(owned_slots(clone, context.relocation), & &1.id) == [clone_slot.id]
          assert_exclusive_slots([context.source.host.id, context.destination.host.id])
        end

        released = Ledger.update!(clone_slot, :release, %{released_at: Ledger.now()})
        assert {:ok, slots} = occupy(context.relocation)
        assert length(slots) == 2
        assert %{released_at: %DateTime{}} = released

        assert [%{id: id, released_at: released_at}] =
                 Ledger.read!(TransferSlot, id: clone_slot.id)

        assert id == released.id
        assert released_at == released.released_at
      else
        assert {:ok, slots} = occupy(context.relocation)

        for _ <- 1..retries do
          assert_sql_error(
            :unique_violation,
            "INSERT INTO compute_transfer_slots (host_id, clone_request_id) VALUES ($1, $2)",
            [uuid(host_id), uuid(clone.id)]
          )

          assert MapSet.new(owned_slots(clone, context.relocation), & &1.id) ==
                   MapSet.new(slots, & &1.id)

          assert_exclusive_slots([context.source.host.id, context.destination.host.id])
        end

        for slot <- slots,
            do: Ledger.update!(slot, :release, %{released_at: Ledger.now()})

        clone_slot =
          Ledger.create!(TransferSlot, :occupy, %{
            host_id: host_id,
            clone_request_id: clone.id
          })

        assert clone_slot.released_at == nil
        assert length(owned_slots(clone, context.relocation)) == 3
      end

      assert_exclusive_slots([context.source.host.id, context.destination.host.id])

      for slot <- owned_slots(clone, context.relocation), is_nil(slot.released_at) do
        Ledger.update!(slot, :release, %{released_at: Ledger.now()})
      end
    end
  end

  test "opposite-role occupancy rejects a claim and rolls back the first slot", context do
    {:ok, other_vm} = Compute.provision(request(), actor: context.owner)

    placements =
      for endpoint <- [context.source, context.destination] do
        Ledger.create!(WorkloadPlacement, :allocate, %{
          vm_id: other_vm.id,
          host_id: endpoint.host.id,
          pool_id: endpoint.pool.id
        })
      end

    other =
      Ledger.create!(
        Relocation,
        :record,
        Map.merge(context.attributes, %{
          vm_id: other_vm.id,
          source_placement_id: List.last(placements).id,
          destination_placement_id: hd(placements).id,
          source_host_id: context.destination.host.id,
          destination_host_id: context.source.host.id,
          request_key: Ash.UUID.generate()
        })
      )

    busy_host = max(context.source.host.id, context.destination.host.id)

    role =
      if busy_host == other.source_host_id,
        do: :source_relocation_id,
        else: :destination_relocation_id

    occupied = Ledger.create!(TransferSlot, :occupy, %{role => other.id, :host_id => busy_host})

    requested_role =
      if role == :source_relocation_id,
        do: "destination_relocation_id",
        else: "source_relocation_id"

    assert_sql_error(
      :unique_violation,
      "INSERT INTO compute_transfer_slots (host_id, #{requested_role}) VALUES ($1, $2)",
      [uuid(busy_host), uuid(context.relocation.id)]
    )

    assert {:error, :transfer_busy} = occupy(context.relocation)
    assert [remaining] = Ledger.read!(TransferSlot)
    assert remaining.id == occupied.id
  end

  test "released ownership is retained and cannot be reacquired by a retry", context do
    assert {:ok, _} = occupy(context.relocation)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE compute_transfer_slots SET released_at = clock_timestamp() WHERE host_id = $1",
      [uuid(context.source.host.id)]
    )

    assert {:error, :transfer_slot_released} = occupy(context.relocation)
    assert length(Ledger.read!(TransferSlot)) == 2
  end

  test "database rejects a second unfinished move for the same VM", context do
    assert_sql_error(
      :unique_violation,
      """
      INSERT INTO compute_relocations
        (vm_id, source_placement_id, destination_placement_id, source_host_id,
         destination_host_id, source_epoch, destination_epoch, original_state,
         requested_by_id, request_key)
      SELECT vm_id, source_placement_id, destination_placement_id, source_host_id,
         destination_host_id, source_epoch, destination_epoch, original_state,
         requested_by_id, 'different-request'
      FROM compute_relocations WHERE id = $1
      """,
      [uuid(context.relocation.id)]
    )
  end

  test "finished history keeps request identity and cannot acquire slots", context do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE compute_relocations SET finished_at = clock_timestamp() WHERE id = $1",
      [uuid(context.relocation.id)]
    )

    assert {:error, :relocation_finished} = occupy(context.relocation)
    assert Ledger.read!(TransferSlot) == []

    assert_sql_error(
      :unique_violation,
      """
      INSERT INTO compute_relocations
        (vm_id, source_placement_id, destination_placement_id, source_host_id,
         destination_host_id, source_epoch, destination_epoch, original_state,
         requested_by_id, request_key)
      SELECT vm_id, source_placement_id, destination_placement_id, source_host_id,
         destination_host_id, source_epoch, destination_epoch, original_state,
         requested_by_id, request_key
      FROM compute_relocations WHERE id = $1
      """,
      [uuid(context.relocation.id)]
    )
  end

  test "database requires the exact next execution epoch", context do
    for epoch <- [0, 1, 3] do
      assert_sql_error(
        :check_violation,
        "UPDATE compute_relocations SET destination_epoch = $1 WHERE id = $2",
        [epoch, uuid(context.relocation.id)]
      )
    end
  end

  test "database rejects endpoint host substitution and same-host movement", context do
    other = host_fixture()

    assert_sql_error(
      :foreign_key_violation,
      "UPDATE compute_relocations SET destination_host_id = $1 WHERE id = $2",
      [uuid(other.host.id), uuid(context.relocation.id)]
    )

    assert_sql_error(
      :check_violation,
      "UPDATE compute_relocations SET destination_host_id = source_host_id WHERE id = $1",
      [uuid(context.relocation.id)]
    )
  end

  test "slot role must match its endpoint and only one role may be recorded", context do
    assert_sql_error(
      :foreign_key_violation,
      "INSERT INTO compute_transfer_slots (host_id, source_relocation_id) VALUES ($1, $2)",
      [uuid(context.destination.host.id), uuid(context.relocation.id)]
    )

    assert_sql_error(
      :check_violation,
      "INSERT INTO compute_transfer_slots (host_id) VALUES ($1)",
      [uuid(context.source.host.id)]
    )
  end

  test "an occupied endpoint cannot be duplicated", context do
    assert {:ok, _} = occupy(context.relocation)

    assert_sql_error(
      :unique_violation,
      "INSERT INTO compute_transfer_slots (host_id, source_relocation_id) VALUES ($1, $2)",
      [uuid(context.source.host.id), uuid(context.relocation.id)]
    )
  end

  test "ordinary users cannot manufacture relocation or stream authority", context do
    assert {:error, %Ash.Error.Forbidden{}} =
             Relocation
             |> Ash.Changeset.for_create(:record, context.attributes, actor: context.owner)
             |> Ash.create()

    assert {:error, %Ash.Error.Forbidden{}} =
             TransferSlot
             |> Ash.Changeset.for_create(
               :occupy,
               %{host_id: context.source.host.id, source_relocation_id: context.relocation.id},
               actor: context.owner
             )
             |> Ash.create()
  end

  defp occupy(relocation) do
    Ledger.transaction(fn ->
      [relocation.source_host_id, relocation.destination_host_id]
      |> Enum.sort()
      |> Enum.each(&Ledger.lock!(Host, &1))

      TransferSlots.occupy_locked!(relocation)
    end)
  end

  @spec owned_slots(CloneRequest.t(), Relocation.t()) :: [TransferSlot.t()]
  defp owned_slots(clone, relocation) do
    Enum.filter(Ledger.read!(TransferSlot), fn slot ->
      slot.clone_request_id == clone.id or slot.source_relocation_id == relocation.id or
        slot.destination_relocation_id == relocation.id
    end)
  end

  @spec assert_exclusive_slots([String.t()]) :: :ok
  defp assert_exclusive_slots(host_ids) do
    slots = Ledger.read!(TransferSlot)

    for host_id <- host_ids do
      assert Enum.count(slots, &(&1.host_id == host_id and is_nil(&1.released_at))) <= 1
    end

    for slot <- slots do
      assert Enum.count(
               [slot.source_relocation_id, slot.destination_relocation_id, slot.clone_request_id],
               &(not is_nil(&1))
             ) == 1
    end

    :ok
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

  defp assert_sql_error(code, sql, args) do
    assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} =
             Ecto.Adapters.SQL.query(Repo, sql, args, mode: :savepoint, log: false)
  end
end
