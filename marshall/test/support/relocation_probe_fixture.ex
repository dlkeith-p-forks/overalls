defmodule Marshall.RelocationProbeFixture do
  @moduledoc "Applied source grant and destination probe records, as the probe exchange records them."
  alias OverallsProtocol.RelocationProbe, as: Wire
  alias Marshall.Compute.{Ledger, NetworkAddress, ProbeRequest, Relocation, VirtualMachine}
  alias Marshall.Compute.WorkloadPlacement

  # @cc [owner:ghuntley,label:verification] probe-fixture-uses-closed-wire
  # applied!/2 MUST persist only commands that round-trip the closed probe codec
  # and bind the relocation's exact current intent, generation and key, so the
  # production ready_request/3 selection and the stop-requires-probe database
  # constraint judge it exactly as they judge an exchange-recorded probe.
  @spec applied!(Relocation.t(), VirtualMachine.t()) :: ProbeRequest.t()
  def applied!(relocation, vm) do
    [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)
    now = DateTime.to_unix(Ledger.now())

    base = %{
      intent: intent(relocation, vm, address.slot),
      generation: vm.generation,
      public_key: relocation.destination_public_key,
      challenge: Ash.UUID.generate(),
      revision: 1,
      expires_at: now + 180
    }

    record!(Map.merge(base, %{phase: :grant, source_endpoint: nil}), relocation.source_host_id)

    record!(
      Map.merge(base, %{phase: :probe, source_endpoint: relocation.source_endpoint}),
      relocation.destination_host_id
    )
  end

  @spec intent(Relocation.t(), VirtualMachine.t(), pos_integer()) :: map()
  defp intent(relocation, vm, slot) do
    endpoint = fn id ->
      [placement] = Ledger.read!(WorkloadPlacement, id: id)
      %{placement_id: placement.id, host_id: placement.host_id, pool_id: placement.pool_id}
    end

    %{
      relocation_id: relocation.id,
      vm_id: relocation.vm_id,
      source: endpoint.(relocation.source_placement_id),
      destination: endpoint.(relocation.destination_placement_id),
      source_epoch: relocation.source_epoch,
      destination_epoch: relocation.destination_epoch,
      workload:
        vm
        |> Map.take([:image_id, :architecture, :profile, :vcpu, :memory_bytes, :disk_bytes])
        |> Map.put(:slot, slot)
    }
  end

  @spec record!(map(), String.t()) :: ProbeRequest.t()
  defp record!(fields, host) do
    command = Map.put(fields, :id, Ash.UUID.generate())
    wire = Wire.encode_command(command)
    {:ok, ^command} = Wire.command(wire)

    ProbeRequest
    |> Ledger.create!(:enqueue, %{
      id: command.id,
      relocation_id: command.intent.relocation_id,
      host_id: host,
      phase: command.phase,
      revision: command.revision,
      request: wire,
      expires_at: DateTime.from_unix!(command.expires_at),
      inserted_at: Ledger.now()
    })
    |> Ledger.update!(:record_result, %{applied_at: Ledger.now()})
  end
end
