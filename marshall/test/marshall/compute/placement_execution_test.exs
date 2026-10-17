defmodule Marshall.Compute.PlacementExecutionTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Compute

  alias Marshall.Compute.{
    Credentials,
    Host,
    Ledger,
    Operation,
    Outcomes,
    PhysicalOutcome,
    ProvisionerControl,
    Reservation,
    VirtualMachine,
    WorkloadPlacement
  }

  setup do
    source = host_fixture()
    owner = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    [original] = Ledger.read!(Operation, vm_id: vm.id)
    destination = host_fixture()

    placement =
      Ledger.create!(WorkloadPlacement, :allocate, %{
        vm_id: vm.id,
        host_id: destination.host.id,
        pool_id: destination.pool.id
      })

    Ledger.create!(
      Reservation,
      :reserve,
      Map.merge(OverallsProtocol.VMShape.reservation(vm), %{
        vm_id: vm.id,
        placement_id: placement.id,
        host_id: placement.host_id,
        pool_id: placement.pool_id
      })
    )

    # Simulate committed authority only. This does not claim a physical transfer.
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      UPDATE compute_virtual_machines SET current_placement_id = $1, execution_epoch = 2 WHERE id = $2
      """,
      [Ecto.UUID.dump!(placement.id), Ecto.UUID.dump!(vm.id)]
    )

    current =
      Ledger.create!(Operation, :enqueue, %{
        vm_id: vm.id,
        placement_id: placement.id,
        execution_epoch: 2,
        generation: vm.generation,
        kind: :start,
        requested_by_id: owner.id
      })

    %{
      source: source,
      destination: destination,
      vm: vm,
      original: original,
      current: current,
      placement: placement
    }
  end

  test "polling never retargets an old operation to the new host", context do
    source = connection(context.source.host)
    destination = connection(context.destination.host)
    assert {:ok, %{"commands" => []}} = exchange(source)
    assert {:ok, %{"commands" => [command]}} = exchange(destination)
    assert command["id"] == context.current.id
    assert command["host_id"] == context.placement.host_id
    assert command["pool_id"] == context.placement.pool_id

    # Receipts belong to the immutable target, even after its VM moves away.
    assert {:ok, _} = exchange(source, [context.original.id])
    assert {:error, :invalid_acknowledgement} = exchange(destination, [context.original.id])
  end

  test "delayed source evidence is retained without changing destination state or capacity",
       context do
    source_event = outcome(context.original, :failed)
    assert {:ok, _} = ingest(context.source.host.id, source_event)
    assert [vm] = Ledger.read!(VirtualMachine, id: context.vm.id)
    assert vm.observed_state == :pending
    assert [%{compute_held: true}] = Ledger.read!(Reservation, placement_id: context.placement.id)

    # Both placements may report local sequence one without a collision.
    assert {:ok, _} = ingest(context.destination.host.id, outcome(context.current, :running))
    assert length(Ledger.read!(PhysicalOutcome, vm_id: context.vm.id, sequence: 1)) == 2
    assert [vm] = Ledger.read!(VirtualMachine, id: context.vm.id)
    assert vm.observed_state == :running
    assert vm.execution_epoch == 2
    assert {:ok, _} = ingest(context.source.host.id, source_event)
    assert {:error, :outcome_conflict} = ingest(context.destination.host.id, source_event)
  end

  test "a renewed epoch suppresses commands even when placement and generation still match",
       context do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE compute_virtual_machines SET execution_epoch = 3 WHERE id = $1",
      [Ecto.UUID.dump!(context.vm.id)]
    )

    assert {:ok, %{"commands" => []}} = exchange(connection(context.destination.host))
    assert {:ok, _} = ingest(context.destination.host.id, outcome(context.current, :running))
    assert [%{observed_state: :pending}] = Ledger.read!(VirtualMachine, id: context.vm.id)
  end

  test "dispatch hints retain the original host after authority moves", context do
    watch_hints()

    assert {:ok, _} =
             Oban.Testing.perform_job(
               Marshall.Compute.Workers.Dispatch,
               %{"primary_key" => %{"id" => context.original.id}},
               repo: Repo
             )

    host = context.source.host.id
    assert_receive {:hint, :host_commands, ^host}
  end

  test "an authenticated source cannot report a destination operation", context do
    assert {:error, :invalid_outcome} =
             ingest(context.source.host.id, outcome(context.current, :running))

    assert [] = Ledger.read!(PhysicalOutcome, vm_id: context.vm.id)
  end

  test "PostgreSQL rejects outcome epochs that disagree with their operation", context do
    event = outcome(context.current, :running)
    assert {:ok, _} = ingest(context.destination.host.id, event)

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE compute_physical_outcomes SET execution_epoch = 99 WHERE id = $1",
               [Ecto.UUID.dump!(event.id)]
             )
  end

  defp connection(host) do
    {:ok, credential} = Credentials.rotate(host.id, 3600)
    session_id = Ash.UUID.generate()

    {:ok, reply} =
      ProvisionerControl.open_execution(
        credential.token,
        %{session_id: session_id, machine_id: host.machine_id}
      )

    %{token: credential.token, session_id: session_id, epoch: reply["epoch"]}
  end

  defp exchange(connection, acknowledgements \\ []) do
    ProvisionerControl.exchange_execution(connection.token, %{
      session_id: connection.session_id,
      epoch: connection.epoch,
      report: nil,
      outcomes: [],
      acknowledgements: acknowledgements
    })
  end

  defp ingest(host_id, event) do
    Ledger.transaction(fn ->
      Ledger.lock!(Host, host_id)
      Outcomes.ingest_locked!(host_id, [event])
    end)
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
      reason: if(state == :failed, do: :execution_failed, else: :none)
    }
  end

  @spec watch_hints() :: :ok
  defp watch_hints do
    parent = self()
    handler = "hints-" <> Ecto.UUID.generate()

    :telemetry.attach(
      handler,
      [:marshall, :control, :hint],
      fn _event, _measurements, %{kind: kind, id: id}, _ -> send(parent, {:hint, kind, id}) end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
  end
end
