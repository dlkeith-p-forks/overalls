defmodule Lilly.Transfer.SourceRevocation do
  @moduledoc "Leased source permit fencing and confirmed sender quiescence."
  require Lilly.Events
  alias OverallsProtocol.RelocationRevocation, as: Wire

  # @cc [owner:ghuntley,label:security;recovery] source-revocation-confirmed-before-receipt
  # execute/3 requires authenticated source control and an operator-selected root.
  # It MUST validate host identity and a bounded live lease before local effects,
  # durably fence the relocation permit and confirm sender lock release before
  # returning. No held host lock is permitted. It MUST NOT delete snapshots/disks,
  # change VM intent, regenerate permissions or release control-plane commitments.
  @spec execute(Path.t(), String.t(), Wire.command()) :: {:ok, Wire.result()} | {:error, atom()}
  def execute(root, host, command) do
    with {:ok, ^command} <- Wire.command(Wire.encode(command)),
         true <-
           command.host_id == host and
             (command.expires_at - System.system_time(:second)) in 1..300,
         :ok <- Lilly.Transfer.SourceExport.revoke(root, host, command.id),
         do: revoked(command),
         else: (_ -> {:error, :source_revocation_unconfirmed})
  end

  # @cc [owner:ghuntley,label:security;observability] source-revocation-outcome-event
  # A confirmed source revocation MUST report only the relocation and placement
  # identifiers; command payloads and paths MUST NOT be logged. Rejections stay
  # deduplicated runtime diagnostics and MUST NOT emit here, because revoke
  # retries replay the permanent tombstone.
  defp revoked(command) do
    Lilly.Events.emit("lilly.cleanup_completed",
      relocation_id: command.id,
      placement_id: command.placement_id
    )

    {:ok, Map.take(command, [:id, :placement_id, :execution_epoch])}
  end
end
