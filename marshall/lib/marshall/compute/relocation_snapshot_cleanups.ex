defmodule Marshall.Compute.RelocationSnapshotCleanups do
  @moduledoc "Authenticated source snapshot cleanup after restoration or logical Delete."
  alias Marshall.Compute.{Credentials, Ledger, Relocation, VirtualMachine}
  alias Marshall.Authorization.SystemActor
  alias OverallsProtocol.RelocationSnapshotCleanup, as: Wire
  require Ash.Query

  # @cc [owner:ghuntley,label:security;recovery] source-snapshots-offer-after-restoration
  # Only restored cancelled sources or sources fenced by logical Delete before
  # handoff may receive cleanup commands. Receipts MUST
  # match the offered source host/placement/old epoch under the current source
  # session and VM lock. Duplicate receipts retain their first timestamp. This
  # records snapshot absence only and MUST NOT release disk/destination holds.
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
          source_host_id == ^host.id and not is_nil(cancellation_requested_at) and
            is_nil(finished_at) and
            (not is_nil(source_restored_at) or not is_nil(deletion_requested_at)) and
            is_nil(source_snapshots_cleaned_at)
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

      unless relocation.cancellation_requested_at != nil and relocation.committed_at == nil and
               relocation.source_snapshot_cleanup_offered_at != nil and
               (relocation.source_restored_at != nil or relocation.deletion_requested_at != nil),
             do: Ledger.rollback(:invalid_outcome)

      if relocation.source_snapshots_cleaned_at == nil,
        do:
          Ledger.update!(relocation, :record_source_snapshot_cleanup, %{
            source_snapshots_cleaned_at: Ledger.now()
          })

      result.id
    else
      _ -> Ledger.rollback(:invalid_outcome)
    end
  end

  defp command!(relocation) do
    Ledger.lock!(VirtualMachine, relocation.vm_id)
    [relocation] = Ledger.read!(Relocation, id: relocation.id)

    if relocation.source_snapshots_cleaned_at == nil and relocation.finished_at == nil and
         relocation.cancellation_requested_at != nil and relocation.committed_at == nil and
         (relocation.source_restored_at != nil or relocation.deletion_requested_at != nil) do
      if relocation.source_snapshot_cleanup_offered_at == nil,
        do:
          Ledger.update!(relocation, :offer_source_snapshot_cleanup, %{
            source_snapshot_cleanup_offered_at: Ledger.now()
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
