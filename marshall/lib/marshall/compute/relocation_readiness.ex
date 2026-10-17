defmodule Marshall.Compute.RelocationReadiness do
  @moduledoc "Authenticated readiness probes and boot-bound receipts after handoff."
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    Credentials,
    Ledger,
    ReadinessRequest,
    Relocation,
    RelocationReadinessState,
    VirtualMachine
  }

  alias OverallsProtocol.RelocationReadiness, as: Wire
  require Ash.Query

  # @cc [owner:ghuntley,label:security;recovery] readiness-receipt-never-revives-expired-authority
  # Exchanges MUST fence the current destination session before VM locks. Only
  # an offered request's exact activation/descriptor/generation may report a boot.
  # Duplicate ready receipts are idempotent; conflicting boot IDs roll back.
  # Late receipts are acknowledged without reviving a failed/expired request.
  # Historical failed-activation receipts MUST remain acknowledgeable after a
  # destination retry without satisfying or fencing the newer activation request.
  # No receipt releases storage, changes placement or authorizes source restart.
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
          destination_host_id == ^host.id and not is_nil(committed_at) and is_nil(finished_at)
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
    with [request] <- Ledger.read!(ReadinessRequest, id: result.id),
         [relocation] <- Ledger.read!(Relocation, id: request.relocation_id),
         true <- relocation.destination_host_id == host do
      vm = Ledger.lock_history!(VirtualMachine, relocation.vm_id)
      [relocation] = Ledger.read!(Relocation, id: relocation.id)

      request =
        if request.id == relocation.activation_operation_id,
          do: RelocationReadinessState.advance_locked!(relocation, vm),
          else: request

      unless request != nil and request.id == result.id and request.offered_at != nil and
               request.requires_boot and
               request.generation == result.generation and
               request.descriptor ==
                 OverallsProtocol.Relocation.encode_descriptor(result.descriptor),
             do: Ledger.rollback(:invalid_outcome)

      case request.status do
        :ready ->
          if request.boot_id != result.boot_id, do: Ledger.rollback(:outcome_conflict)

        :failed ->
          :ok

        :pending ->
          unless request.id == relocation.activation_operation_id,
            do: Ledger.rollback(:invalid_outcome)

          Ledger.update!(request, :ready, %{boot_id: result.boot_id, completed_at: Ledger.now()})

          if relocation.phase == :checking_destination,
            do: Ledger.update!(relocation, :confirm_readiness, %{})

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

    case RelocationReadinessState.advance_locked!(relocation, vm) do
      %{status: :pending, requires_boot: true} = request ->
        now = Ledger.now()
        remaining = DateTime.diff(request.deadline_at, now, :millisecond)

        if remaining > 0 do
          if request.offered_at == nil, do: Ledger.update!(request, :offer, %{offered_at: now})

          command = %{
            "id" => request.id,
            "descriptor" => request.descriptor,
            "generation" => request.generation,
            "timeout_ms" => min(remaining, 600_000),
            "expires_at" =>
              min(
                DateTime.to_unix(now) + 180,
                div(DateTime.to_unix(request.deadline_at, :millisecond) + 999, 1000)
              )
          }

          unless match?({:ok, _}, Wire.command(command)),
            do: Ledger.rollback(:reconciliation_required)

          [command]
        else
          []
        end

      _ ->
        []
    end
  end
end
