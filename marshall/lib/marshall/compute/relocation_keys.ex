defmodule Marshall.Compute.RelocationKeys do
  @moduledoc "Authenticated destination key preparation backed by immutable relocation identity."
  alias Marshall.Compute.{Credentials, Ledger, Relocation, VirtualMachine}
  alias Marshall.Authorization.SystemActor
  alias OverallsProtocol.RelocationKeys, as: Wire
  require Ash.Query

  # @cc [owner:ghuntley,label:security;concurrency] relocation-key-session-and-owner
  # An exchange MUST authenticate and lock the destination host's current v4
  # session before recording results. Only that relocation's destination may
  # publish its public key for the exact destination placement/epoch, exactly
  # once; matching retries are idempotent and
  # conflicts roll back the whole exchange. Host locks precede VM locks. A key
  # result MUST NOT stop guests, grant permits or release any reservation.
  # Cancellation MUST suppress new offers/renewals while retaining late physical facts.
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
          destination_host_id == ^host.id and is_nil(finished_at) and
            is_nil(cancellation_requested_at) and
            is_nil(destination_public_key) and not is_nil(source_endpoint)
        )
        |> Ash.Query.sort(inserted_at: :asc, id: :asc)
        |> Ash.Query.limit(16)
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.map(fn relocation ->
          wire =
            Wire.encode(%{
              id: relocation.id,
              host_id: host.id,
              placement_id: relocation.destination_placement_id,
              execution_epoch: relocation.destination_epoch,
              source_host_id: relocation.source_host_id,
              source_endpoint: relocation.source_endpoint
            })

          unless match?({:ok, _}, Wire.command(wire)),
            do: Ledger.rollback(:reconciliation_required)

          wire
        end)

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
           relocation.destination_host_id == host and relocation.source_endpoint != nil and
             relocation.destination_placement_id == result.placement_id and
             relocation.destination_epoch == result.execution_epoch do
      # Completion/cancellation also takes the VM lock after endpoint host locks.
      Ledger.lock_history!(VirtualMachine, relocation.vm_id)
      [relocation] = Ledger.read!(Relocation, id: result.id)

      cond do
        relocation.destination_public_key == result.public_key ->
          :ok

        relocation.destination_public_key != nil ->
          Ledger.rollback(:outcome_conflict)

        relocation.finished_at != nil ->
          Ledger.rollback(:invalid_outcome)

        true ->
          Ledger.update!(relocation, :record_key, %{destination_public_key: result.public_key})
      end

      result.id
    else
      _ -> Ledger.rollback(:invalid_outcome)
    end
  end
end
