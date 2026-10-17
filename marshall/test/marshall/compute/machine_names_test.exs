defmodule Marshall.Compute.MachineNamesTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Compute
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes, VirtualMachine}

  setup do
    host_fixture()
    %{owner: user(), other: user()}
  end

  test "names resolve through current account permission and UUIDs remain valid", %{
    owner: owner,
    other: other
  } do
    assert {:ok, vm} = Compute.provision(request(%{name: "example-machine"}), actor: owner)
    assert {:ok, by_name} = Compute.resolve_vm(%{reference: vm.name}, actor: owner)
    assert {:ok, by_id} = Compute.resolve_vm(%{reference: vm.id}, actor: owner)
    assert by_name == by_id
    assert by_name.name == "example-machine"
    assert {:error, _} = Compute.resolve_vm(%{reference: vm.name}, actor: other)
    assert {:error, _} = Compute.resolve_vm(%{reference: "absent-machine"}, actor: other)
    assert {:error, _} = Compute.provision(request(%{name: vm.name}), actor: other)
    assert length(Ledger.read!(VirtualMachine)) == 1

    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: vm.id,
                 email: to_string(other.email),
                 role: :viewer,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    assert {:ok, _} = Compute.resolve_vm(%{reference: vm.name}, actor: other)

    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: vm.id,
                 email: to_string(other.email),
                 role: :revoked,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    assert {:error, _} = Compute.resolve_vm(%{reference: vm.name}, actor: other)
  end

  test "the database refuses a machine row without a name", %{owner: owner} do
    {:ok, original} = Compute.provision(request(), actor: owner)

    insert = fn ->
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        """
        INSERT INTO compute_virtual_machines
          (id, current_placement_id, owner_id, image_id, architecture, profile, vcpu,
           memory_bytes, disk_bytes, idempotency_key, provisioning_sizes)
        SELECT $1::text::uuid, $2::text::uuid, owner_id, image_id, architecture, profile,
          vcpu, memory_bytes, disk_bytes, $3::text, provisioning_sizes
        FROM compute_virtual_machines WHERE id = $4::text::uuid
        """,
        [Ash.UUID.generate(), Ash.UUID.generate(), Ash.UUID.generate(), original.id]
      )
    end

    assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation, column: "name"}}} =
             Marshall.Repo.transaction(fn ->
               try do
                 insert.()
               rescue
                 error in Postgrex.Error -> Marshall.Repo.rollback(error)
               end
             end)

    assert [_] = Ledger.read!(VirtualMachine)
  end

  property "retries pin the generated or chosen name and reject changing it", %{owner: owner} do
    check all(suffix <- integer(1..1_000_000), explicit? <- boolean(), max_runs: 12) do
      params = request(%{name: if(explicit?, do: "chosen-#{suffix}")})
      assert {:ok, vm} = Compute.provision(params, actor: owner)
      assert OverallsProtocol.MachineName.valid?(vm.name)
      assert {:ok, replay} = Compute.provision(params, actor: owner)
      assert replay.id == vm.id
      assert replay.name == vm.name

      assert {:error, error} =
               Compute.provision(Map.put(params, :name, "different-#{suffix}"), actor: owner)

      assert Exception.message(error) =~ "idempotency_conflict"
      # Reclaim through the actual outcome path so each generated case leaves capacity.
      assert {:ok, deletion} =
               Compute.lifecycle(
                 %{vm_id: vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()},
                 actor: owner
               )

      assert {:ok, _} = ingest(vm.host_id, outcome(deletion, 1, :deleted))
    end
  end

  test "logical deletion retains a name until confirmed cleanup; old retries retain identity", %{
    owner: owner,
    other: other
  } do
    params = request(%{name: "reusable-machine"})
    {:ok, vm} = Compute.provision(params, actor: owner)

    {:ok, deletion} =
      Compute.lifecycle(%{vm_id: vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()},
        actor: owner
      )

    assert {:error, _} = Compute.provision(request(%{name: vm.name}), actor: other)
    assert {:ok, _} = ingest(vm.host_id, outcome(deletion, 1, :unknown))
    assert {:error, _} = Compute.provision(request(%{name: vm.name}), actor: other)
    assert {:ok, _} = ingest(vm.host_id, outcome(deletion, 2, :deleted))
    assert {:ok, successor} = Compute.provision(request(%{name: vm.name}), actor: other)
    refute successor.id == vm.id
    assert {:ok, replay} = Compute.provision(params, actor: owner)
    assert replay.id == vm.id
    assert replay.archived_at != nil
    assert {:error, _} = Compute.resolve_vm(%{reference: vm.name}, actor: owner)
    assert {:ok, %{id: id}} = Compute.resolve_vm(%{reference: vm.name}, actor: other)
    assert id == successor.id
    assert length(Ledger.read!(Operation, vm_id: successor.id)) == 1
  end

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
      compute_empty: state == :deleted,
      disk_present: state != :deleted,
      cleanup_complete: state == :deleted,
      reason: if(state == :unknown, do: :unknown, else: :none)
    }
  end
end
