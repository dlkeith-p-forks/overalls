defmodule Marshall.Compute.RelocationKeyRetirement do
  @moduledoc "Authenticated destination key erasure after confirmed source retirement."
  alias Marshall.Compute.{CleanupRequest, Credentials, Ledger, Relocation, VirtualMachine}
  alias OverallsProtocol.RelocationKeyRetirement, as: Wire
  alias Marshall.Authorization.SystemActor
  require Ash.Query

  # @cc [owner:ghuntley,label:security;recovery] key-retirement-offer-before-receipt
  # The destination session MUST be fenced before VM locks. Only a retained source
  # cleanup request authorized by its deleted outcome may offer key retirement.
  # Receipts MUST match the offered placement/epoch, survive duplicates and enqueue
  # reconciliation without releasing either host's commitments in this exchange.
  @spec exchange(String.t(), Wire.exchange()) :: {:ok, map()} | {:error, term()}
  def exchange(token, message) do
    Credentials.with_host(token, fn host ->
      unless host.connection_session_id == message.session_id and
               host.connection_epoch == message.epoch,
             do: Ledger.rollback(:stale_connection)

      accepted = Enum.map(Enum.sort_by(message.results, & &1.id), &accept!(host.id, &1))

      commands =
        CleanupRequest
        |> Ash.Query.filter(
          relocation.destination_host_id == ^host.id and
            not is_nil(key_requested_at) and is_nil(key_retired_at)
        )
        |> Ash.Query.sort(id: :asc)
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

      case Ledger.read!(CleanupRequest, id: relocation.id) do
        [%{key_offered_at: offered} = request] when not is_nil(offered) ->
          if request.key_retired_at == nil do
            Ledger.update!(request, :retire_key, %{key_retired_at: Ledger.now()})
            Ledger.update!(relocation, :schedule, %{})
          end

          result.id

        _ ->
          Ledger.rollback(:invalid_outcome)
      end
    else
      _ -> Ledger.rollback(:invalid_outcome)
    end
  end

  defp command!(request) do
    [relocation] = Ledger.read!(Relocation, id: request.id)
    Ledger.lock!(VirtualMachine, relocation.vm_id)
    [request] = Ledger.read!(CleanupRequest, id: request.id)

    if request.key_retired_at == nil do
      if request.key_offered_at == nil,
        do: Ledger.update!(request, :offer_key_retirement, %{key_offered_at: Ledger.now()})

      [
        Wire.encode(%{
          id: request.id,
          host_id: relocation.destination_host_id,
          placement_id: relocation.destination_placement_id,
          execution_epoch: relocation.destination_epoch,
          expires_at: DateTime.to_unix(Ledger.now()) + 180
        })
      ]
    else
      []
    end
  end
end
