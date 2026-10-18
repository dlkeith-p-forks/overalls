defmodule Marshall.Compute.RelocationImports do
  @moduledoc "Destination-local adoption authorization and retained final import evidence."
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    Credentials,
    Ledger,
    Relocation,
    RelocationReceives,
    SourcePermitRequest,
    VirtualMachine
  }

  alias OverallsProtocol.RelocationImport, as: Wire
  require Ash.Query

  # @cc [owner:ghuntley,label:security;recovery] import-exchange-current-destination
  # Import work MUST authenticate and lock the current destination session before
  # VM serialization. Only a verified received final disk/checkpoint under unchanged quiescent
  # source authority and retained holds/slots may be offered. Persist request intent
  # before issuing its renewable 180-second control lease. Receipts MUST match that
  # retained request, descriptor and local GUID; conflicting batches roll back.
  # Adoption evidence MUST NOT change placement/epoch or release commitments.
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
            is_nil(cancellation_requested_at)
        )
        |> Ash.Query.sort(vm_id: :asc)
        |> Ash.Query.limit(16)
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.flat_map(&commands!/1)

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
    with [request] <- Ledger.read!(SourcePermitRequest, id: result.id),
         [relocation] <- Ledger.read!(Relocation, id: request.relocation_id),
         true <- relocation.destination_host_id == host do
      Ledger.lock_history!(VirtualMachine, relocation.vm_id)
      [request] = Ledger.read!(SourcePermitRequest, id: result.id)

      unless request.import_requested_at != nil and
               request.descriptor ==
                 OverallsProtocol.Relocation.encode_descriptor(result.descriptor) and
               request.destination_dataset_guid == result.dataset_guid,
             do: Ledger.rollback(:invalid_outcome)

      if request.destination_imported_at == nil do
        Ledger.update!(request, :record_import, %{destination_imported_at: Ledger.now()})

        if relocation.phase == :importing,
          do: Ledger.update!(relocation, :confirm_import, %{})

        Ledger.update!(relocation, :schedule, %{})
      end

      request.id
    else
      _ -> Ledger.rollback(:invalid_outcome)
    end
  end

  defp commands!(relocation) do
    vm = Ledger.lock!(VirtualMachine, relocation.vm_id)
    [relocation] = Ledger.read!(Relocation, id: relocation.id)

    case RelocationReceives.final_received(relocation, vm) do
      %{destination_imported_at: nil} = request ->
        now = Ledger.now()

        if request.import_requested_at == nil do
          Ledger.update!(request, :prepare_import, %{import_requested_at: now})
          Ledger.update!(relocation, :begin_import, %{})
        end

        command = %{
          "id" => request.id,
          "descriptor" => request.descriptor,
          "dataset_guid" => request.destination_dataset_guid,
          "source_endpoint" => relocation.source_endpoint,
          "expires_at" => DateTime.to_unix(now) + 180
        }

        unless match?({:ok, _}, Wire.command(command)),
          do: Ledger.rollback(:reconciliation_required)

        [command]

      _ ->
        []
    end
  end
end
