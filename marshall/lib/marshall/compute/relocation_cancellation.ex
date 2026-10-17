defmodule Marshall.Compute.RelocationCancellation do
  @moduledoc "Authorized cancellation intent serialized against relocation handoff."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Compute.{Host, Ledger, Relocation, VirtualMachine}

  # @cc [owner:ghuntley,label:security;concurrency;recovery] cancellation-before-commit-only
  # Cancellation MUST recheck manage permission under sorted endpoint host locks
  # followed by the VM lock. It MUST reject committed handoff, preserve the first
  # cancellation identity on retries, and atomically enqueue reconciliation. Intent
  # alone MUST NOT restore execution, discard physical receipts or release holds.
  @impl true
  def run(input, _, context) do
    result =
      Ledger.transaction(
        fn ->
          relocation =
            case Ledger.read!(Relocation, id: input.arguments.relocation_id) do
              [relocation] -> relocation
              [] -> Ledger.rollback(:forbidden)
            end

          for id <- Enum.sort([relocation.source_host_id, relocation.destination_host_id]),
              do: Ledger.lock!(Host, id)

          vm = Ledger.lock!(VirtualMachine, relocation.vm_id)
          unless vm, do: Ledger.rollback(:forbidden)
          Marshall.Access.Authorization.require!(vm, context.actor, "manage")
          [relocation] = Ledger.read!(Relocation, id: relocation.id)

          cond do
            relocation.committed_at != nil ->
              Ledger.rollback(:relocation_committed)

            relocation.cancellation_requested_at != nil ->
              relocation

            relocation.finished_at != nil ->
              Ledger.rollback(:relocation_finished)

            vm.archived_at != nil or vm.current_placement_id != relocation.source_placement_id or
                vm.execution_epoch != relocation.source_epoch ->
              Ledger.rollback(:placement_changed)

            true ->
              Ledger.update!(relocation, :request_cancellation, %{
                cancellation_requested_at: Ledger.now(),
                cancellation_requested_by_id: context.actor.id
              })
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
