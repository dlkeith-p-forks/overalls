defmodule Marshall.Compute.RelocationDestinationCleanups do
  @moduledoc "Authenticated destination disk reclamation for cancelled relocations."
  alias Marshall.Compute.{
    Credentials,
    Ledger,
    Relocation,
    VirtualMachine,
    WorkloadPlacement,
    NetworkAddress
  }

  alias Marshall.Authorization.SystemActor
  alias OverallsProtocol.RelocationDestinationCleanup, as: Wire
  require Ash.Query

  # @cc [owner:ghuntley,label:security;recovery] destination-cleanup-offer-before-receipt
  # Exchanges MUST fence the destination session before VM locks. Only cancelled,
  # uncommitted relocations may offer cleanup. Receipts MUST match the offered
  # destination placement/epoch and survive duplicates. A receipt records only
  # destination reclamation; it MUST NOT restore execution or release reservations.
  @spec exchange(String.t(), Wire.exchange()) :: {:ok, map()} | {:error, term()}
  def exchange(token, message) do
    Credentials.with_host(token, fn host ->
      unless host.connection_session_id == message.session_id and
               host.connection_epoch == message.epoch,
             do: Ledger.rollback(:stale_connection)

      accepted = Enum.map(Enum.sort_by(message.results, & &1.id), &accept!(host.id, &1))

      commands =
        Relocation
        |> Ash.Query.filter(
          destination_host_id == ^host.id and not is_nil(cancellation_requested_at) and
            is_nil(finished_at) and is_nil(destination_cleaned_at)
        )
        |> Ash.Query.sort(vm_id: :asc)
        |> Ash.Query.limit(16)
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.flat_map(&command!/1)

      %{
        "version" => 4,
        "host_id" => host.id,
        "session_id" => message.session_id,
        "epoch" => host.connection_epoch,
        "commands" => commands,
        "acknowledgements" => accepted
      }
    end)
  end

  defp accept!(host, result) do
    with [relocation] <- Ledger.read!(Relocation, id: result.id),
         true <-
           relocation.destination_host_id == host and
             relocation.destination_placement_id == result.placement_id and
             relocation.destination_epoch == result.execution_epoch do
      Ledger.lock_history!(VirtualMachine, relocation.vm_id)
      [relocation] = Ledger.read!(Relocation, id: result.id)

      unless relocation.cancellation_requested_at != nil and relocation.committed_at == nil and
               relocation.destination_cleanup_offered_at != nil,
             do: Ledger.rollback(:invalid_outcome)

      if relocation.destination_cleaned_at == nil,
        do:
          Ledger.update!(relocation, :record_destination_cleanup, %{
            destination_cleaned_at: Ledger.now()
          })

      result.id
    else
      _ -> Ledger.rollback(:invalid_outcome)
    end
  end

  defp command!(relocation) do
    Ledger.lock!(VirtualMachine, relocation.vm_id)
    [relocation] = Ledger.read!(Relocation, id: relocation.id)

    if relocation.destination_cleaned_at == nil and relocation.finished_at == nil and
         relocation.cancellation_requested_at != nil and relocation.committed_at == nil do
      if relocation.destination_cleanup_offered_at == nil,
        do:
          Ledger.update!(relocation, :offer_destination_cleanup, %{
            destination_cleanup_offered_at: Ledger.now()
          })

      [vm] = Ledger.read!(VirtualMachine, id: relocation.vm_id)
      [source] = Ledger.read!(WorkloadPlacement, id: relocation.source_placement_id)
      [destination] = Ledger.read!(WorkloadPlacement, id: relocation.destination_placement_id)
      [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)

      intent = %{
        relocation_id: relocation.id,
        vm_id: vm.id,
        source: endpoint(source),
        destination: endpoint(destination),
        source_epoch: relocation.source_epoch,
        destination_epoch: relocation.destination_epoch,
        workload:
          vm
          |> Map.take([:image_id, :architecture, :profile, :vcpu, :memory_bytes, :disk_bytes])
          |> Map.put(:slot, address.slot)
      }

      wire =
        Wire.encode(%{
          id: relocation.id,
          intent: intent,
          expires_at: DateTime.to_unix(Ledger.now()) + 180
        })

      unless match?({:ok, _}, Wire.command(wire)), do: Ledger.rollback(:reconciliation_required)
      [wire]
    else
      []
    end
  end

  defp endpoint(placement),
    do: %{placement_id: placement.id, host_id: placement.host_id, pool_id: placement.pool_id}
end
