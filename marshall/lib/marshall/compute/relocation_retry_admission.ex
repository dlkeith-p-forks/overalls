defmodule Marshall.Compute.RelocationRetryAdmission do
  @moduledoc "Authorized, idempotent restart of a failed committed destination."
  use Ash.Resource.Actions.Implementation

  alias Marshall.Compute.{
    Host,
    Ledger,
    Lifecycle,
    Operation,
    Relocation,
    RelocationRetry,
    RelocationRetryState,
    VirtualMachine
  }

  # @cc [owner:ghuntley,label:security;recovery;concurrency] destination-retry-never-rolls-back
  # Retry MUST recheck manage permission under sorted endpoint locks before the
  # VM lock. It may stop only the unchanged committed destination after failed
  # readiness/activation, never the fenced source. Stop intent, generation, retry
  # identity and reconciliation MUST commit atomically. Exact authorized retries
  # return their retained request without another stop or a renewed deadline.
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
              unless RelocationRetryState.retryable?(r, vm),
                do: Ledger.rollback(:relocation_retry_unavailable)

              Ledger.update!(r, :begin_retry, %{})
              Lifecycle.cancel_operations!(vm.id)

              vm =
                Ledger.intent!(vm, %{
                  generation: Lifecycle.next_generation!(vm),
                  desired_state: :stopped,
                  crash_restart_times: []
                })

              operation =
                Ledger.create!(Operation, :enqueue, %{
                  vm_id: vm.id,
                  placement_id: vm.current_placement_id,
                  execution_epoch: vm.execution_epoch,
                  generation: vm.generation,
                  kind: :stop,
                  initiator: :relocation,
                  relocation_id: r.id
                })

              retry =
                Ledger.create!(RelocationRetry, :record, %{
                  relocation_id: r.id,
                  vm_id: vm.id,
                  requested_by_id: context.actor.id,
                  request_key: input.arguments.idempotency_key,
                  stop_operation_id: operation.id,
                  stop_generation: operation.generation
                })

              Ledger.update!(r, :schedule, %{})
              retry
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
