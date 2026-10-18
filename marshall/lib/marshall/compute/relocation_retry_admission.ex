defmodule Marshall.Compute.RelocationRetryAdmission do
  @moduledoc "Authorized lookup of retained destination retry receipts."
  use Ash.Resource.Actions.Implementation

  alias Marshall.Compute.{
    Host,
    Ledger,
    Relocation,
    RelocationRetry,
    VirtualMachine
  }

  # @cc [owner:ghuntley,label:security;recovery;concurrency] destination-retry-never-rolls-back
  # Retry MUST recheck manage permission under sorted endpoint locks before the
  # VM lock. Exact historical requests return their retained receipt. New retry
  # keys MUST be refused without changing intent, operations, capacity or history:
  # a failed memory restore never authorizes a cold start or checkpoint replay.
  @impl true
  def run(input, _, context) do
    result =
      Ledger.transaction(
        fn ->
          r =
            case Ledger.read!(Relocation, id: input.arguments.relocation_id) do
              [r] -> r
              [] -> Ledger.rollback(:forbidden)
            end

          for id <- Enum.sort([r.source_host_id, r.destination_host_id]),
              do: Ledger.lock!(Host, id)

          vm = Ledger.lock_history!(VirtualMachine, r.vm_id)
          unless vm, do: Ledger.rollback(:forbidden)
          Marshall.Access.Authorization.require!(vm, context.actor, "manage")
          [r] = Ledger.read!(Relocation, id: r.id)

          case Ledger.read!(RelocationRetry,
                 relocation_id: r.id,
                 requested_by_id: context.actor.id,
                 request_key: input.arguments.idempotency_key
               ) do
            [retry] ->
              retry

            [] ->
              Ledger.rollback(:relocation_retry_unavailable)
          end
        end,
        context.actor
      )

    case result do
      {:error, reason} when is_atom(reason) ->
        {:error, Marshall.Compute.Error.exception(reason: reason)}

      other ->
        other
    end
  end
end
