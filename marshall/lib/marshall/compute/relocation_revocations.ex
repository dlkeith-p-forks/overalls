defmodule Marshall.Compute.RelocationRevocations do
  @moduledoc "Authenticated source-export revocation receipts after cancellation or committed handoff."
  alias Marshall.Compute.{Credentials, Ledger, Relocation, VirtualMachine}
  alias Marshall.Authorization.SystemActor
  alias OverallsProtocol.RelocationRevocation, as: Wire
  require Ash.Query

  # @cc [owner:ghuntley,label:security;recovery] source-revocation-offer-before-receipt
  # Exchanges MUST fence the source session before VM locks. Only cancelled or
  # committed relocations may offer revocation; active pre-handoff transfers MUST
  # retain their permissions. Receipts MUST match the offered
  # source placement/epoch and survive duplicates. A receipt records stream
  # revocation only; it MUST NOT restore execution or release any reservation.
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
          source_host_id == ^host.id and
            (not is_nil(cancellation_requested_at) or not is_nil(committed_at)) and
            is_nil(finished_at) and is_nil(source_revoked_at)
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
           relocation.source_host_id == host and
             relocation.source_placement_id == result.placement_id and
             relocation.source_epoch == result.execution_epoch do
      Ledger.lock_history!(VirtualMachine, relocation.vm_id)
      [relocation] = Ledger.read!(Relocation, id: result.id)

      unless (relocation.cancellation_requested_at != nil or relocation.committed_at != nil) and
               relocation.source_revocation_offered_at != nil,
             do: Ledger.rollback(:invalid_outcome)

      if relocation.source_revoked_at == nil,
        do:
          Ledger.update!(relocation, :record_source_revocation, %{source_revoked_at: Ledger.now()})

      result.id
    else
      _ -> Ledger.rollback(:invalid_outcome)
    end
  end

  defp command!(relocation) do
    Ledger.lock!(VirtualMachine, relocation.vm_id)
    [relocation] = Ledger.read!(Relocation, id: relocation.id)

    if relocation.source_revoked_at == nil and relocation.finished_at == nil and
         (relocation.cancellation_requested_at != nil or relocation.committed_at != nil) do
      if relocation.source_revocation_offered_at == nil,
        do:
          Ledger.update!(relocation, :offer_source_revocation, %{
            source_revocation_offered_at: Ledger.now()
          })

      [
        Wire.encode(%{
          id: relocation.id,
          host_id: relocation.source_host_id,
          placement_id: relocation.source_placement_id,
          execution_epoch: relocation.source_epoch,
          expires_at: DateTime.to_unix(Ledger.now()) + 180
        })
      ]
    else
      []
    end
  end
end
