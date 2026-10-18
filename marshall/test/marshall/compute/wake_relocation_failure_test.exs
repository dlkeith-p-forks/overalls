defmodule Marshall.Compute.WakeRelocationFailureTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures

  alias Marshall.Compute

  alias Marshall.Compute.{
    Ledger,
    NetworkAddress,
    Operation,
    Relocation,
    Reservation,
    SourcePermitRequest,
    TransferSlot,
    VirtualMachine,
    Wake,
    WakeRequest,
    WorkloadPlacement
  }

  @type context :: %{vm: VirtualMachine.t(), relocation: Relocation.t(), wake: WakeRequest.t()}

  # @cc [owner:ghuntley,label:verification;recovery;capacity] wake-failed-move-retains-all-custody
  # A wake's exact committed activation/readiness refusal MUST finish demand
  # once, retaining both placements, all holds, operations and relocation state.
  # These seeded DB receipts establish control-plane progress, not physical
  # checkpoint continuity, valid transfer evidence or native restore behavior.
  for phase <- [:activation_failed, :readiness_failed] do
    test "#{phase} finishes the exact committed wake without releasing custody" do
      c = fixture(unquote(phase), true)
      before = custody(c)

      assert {:ok, :finished} = Wake.advance(c.wake.id)
      assert [wake] = Ledger.read!(WakeRequest, id: c.wake.id)
      assert wake.status == :failed and wake.failure_reason == :execution_failed
      assert wake.finished_at != nil
      assert custody(c) == before

      assert {:ok, :finished} = Wake.advance(c.wake.id)
      assert Ledger.read!(WakeRequest, id: wake.id) == [wake]
      assert custody(c) == before
    end

    test "#{phase} without a handoff commit leaves wake pending" do
      c = fixture(unquote(phase), false)
      before = custody(c)
      wake_before = Ledger.read!(WakeRequest, id: c.wake.id)
      assert {:ok, :waiting} = Wake.advance(c.wake.id)
      assert Ledger.read!(WakeRequest, id: c.wake.id) == wake_before
      assert custody(c) == before
    end
  end

  test "a failure cannot finish demand without its exact relocation association" do
    c = fixture(:activation_failed, true)
    wake = Ash.Seed.update!(c.wake, %{relocation_id: nil})
    before = custody(c)
    wake_before = Ledger.read!(WakeRequest, id: wake.id)
    assert {:ok, :waiting} = Wake.advance(wake.id)
    assert Ledger.read!(WakeRequest, id: wake.id) == wake_before
    assert custody(c) == before
  end

  @spec fixture(:activation_failed | :readiness_failed, boolean()) :: context()
  defp fixture(phase, committed?) do
    _source = host_fixture()
    actor = user()
    {:ok, vm} = Compute.provision(request(), actor: actor)
    [provision] = Ledger.read!(Operation, vm_id: vm.id)
    Ledger.update!(provision, :complete, %{})
    vm = Ledger.update!(vm, :observe, %{observed_state: :running})
    _destination = host_fixture()

    {:ok, relocation} =
      Compute.relocate(%{vm_id: vm.id, idempotency_key: Ash.UUID.generate()}, actor: actor)

    {:ok, wake} = Wake.request(vm.id, :user, actor, Ash.UUID.generate())
    vm = Ledger.update!(vm, :observe, %{observed_state: :unknown})

    relocation =
      Ash.Seed.update!(relocation, %{
        requested_by_id: nil,
        wake_request_id: wake.id,
        phase: phase
      })

    relocation = if committed?, do: seed_commit!(relocation, vm), else: relocation
    wake = Ledger.update!(wake, :advance, %{status: :relocating, relocation_id: relocation.id})
    %{vm: vm, relocation: relocation, wake: wake}
  end

  @spec seed_commit!(Relocation.t(), VirtualMachine.t()) :: Relocation.t()
  defp seed_commit!(relocation, vm) do
    [source] = Ledger.read!(WorkloadPlacement, id: relocation.source_placement_id)
    [destination] = Ledger.read!(WorkloadPlacement, id: relocation.destination_placement_id)
    [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)

    intent = %{
      relocation_id: relocation.id,
      vm_id: vm.id,
      source: Map.take(source, [:host_id, :pool_id]) |> Map.put(:placement_id, source.id),
      destination:
        Map.take(destination, [:host_id, :pool_id]) |> Map.put(:placement_id, destination.id),
      source_epoch: relocation.source_epoch,
      destination_epoch: relocation.destination_epoch,
      workload:
        Map.take(vm, [:image_id, :architecture, :profile, :vcpu, :memory_bytes, :disk_bytes])
        |> Map.put(:slot, address.slot)
    }

    command = %{
      id: Ash.UUID.generate(),
      intent: intent,
      generation: vm.generation,
      public_key: transfer_endpoint()["host_key"],
      revision: 1,
      expires_at: DateTime.to_unix(Ledger.now()) + 180,
      to_guid: nil
    }

    imported =
      Ledger.create!(SourcePermitRequest, :enqueue, %{
        id: command.id,
        relocation_id: relocation.id,
        source_host_id: source.host_id,
        revision: 1,
        request: OverallsProtocol.RelocationSource.encode_command(command)
      })

    activation =
      Ash.Seed.seed!(Operation, %{
        vm_id: vm.id,
        placement_id: destination.id,
        execution_epoch: relocation.destination_epoch,
        generation: vm.generation + 1,
        kind: :resume,
        initiator: :relocation,
        relocation_id: relocation.id,
        command_snapshot: %{}
      })

    Ash.Seed.update!(relocation, %{
      committed_at: Ledger.now(),
      import_request_id: imported.id,
      activation_operation_id: activation.id,
      activation_generation: activation.generation
    })
  end

  @spec custody(context()) :: map()
  defp custody(c) do
    %{
      vm: Ledger.read!(VirtualMachine, id: c.vm.id),
      relocation: Ledger.read!(Relocation, id: c.relocation.id),
      holds: Ledger.read!(Reservation, vm_id: c.vm.id) |> Enum.sort_by(& &1.id),
      placements: Ledger.read!(WorkloadPlacement, vm_id: c.vm.id) |> Enum.sort_by(& &1.id),
      operations: Ledger.read!(Operation, vm_id: c.vm.id) |> Enum.sort_by(& &1.id),
      slots:
        (Ledger.read!(TransferSlot, source_relocation_id: c.relocation.id) ++
           Ledger.read!(TransferSlot, destination_relocation_id: c.relocation.id))
        |> Enum.sort_by(& &1.id)
    }
  end
end
