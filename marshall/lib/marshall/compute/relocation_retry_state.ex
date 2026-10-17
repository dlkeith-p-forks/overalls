defmodule Marshall.Compute.RelocationRetryState do
  @moduledoc "Physical-stop-gated reactivation on the authoritative destination only."
  alias Marshall.Compute.{
    Host,
    Ledger,
    Lifecycle,
    Operation,
    PhysicalOutcome,
    ReadinessRequest,
    Relocation,
    RelocationRetry,
    Reservation,
    RestartCapacity,
    VirtualMachine
  }

  # @cc [owner:ghuntley,label:recovery;security] destination-retry-eligibility
  # Retry eligibility requires the exact current committed destination, retained
  # source copy and failed readiness or failed/unknown activation. Delete, finish,
  # prior successful readiness, changed authority and a pending retry MUST deny it.
  # This predicate grants no execution or capacity and callers must serialize mutations.
  @spec retryable?(Relocation.t(), VirtualMachine.t()) :: boolean()
  def retryable?(r, vm) do
    r.committed_at != nil and r.finished_at == nil and r.deletion_requested_at == nil and
      r.original_state == :running and vm.archived_at == nil and
      vm.current_placement_id == r.destination_placement_id and
      vm.execution_epoch == r.destination_epoch and vm.generation == r.activation_generation and
      vm.desired_state == :running and
      Ledger.read!(RelocationRetry, relocation_id: r.id, finished_at: [is_nil: true]) == [] and
      match?([%{disk_held: true}], Ledger.read!(Reservation, placement_id: r.source_placement_id)) and
      failed_activation?(r, vm)
  end

  defp failed_activation?(r, vm) do
    case Ledger.read!(ReadinessRequest, id: r.activation_operation_id) do
      [%{status: :failed}] -> true
      [] -> vm.observed_state in [:failed, :unknown]
      _ -> false
    end
  end

  @spec active(Relocation.t()) :: RelocationRetry.t() | nil
  def active(r),
    do:
      List.first(Ledger.read!(RelocationRetry, relocation_id: r.id, finished_at: [is_nil: true]))

  # @cc [owner:ghuntley,label:capacity;recovery;security] retry-stop-before-new-activation
  # With both endpoint hosts and VM locked, reactivation MUST require the retry's
  # exact immutable physical stopped outcome with empty compute and retained disk.
  # Fresh full-shape startup capacity and the retained portable bundle are required again.
  # New generation, startup hold, activation outbox and relocation activation
  # reference MUST commit atomically. Never modify placement, epoch, old readiness
  # deadlines/results, source authority or retained disk/snapshot holds.
  @spec advance_locked!(RelocationRetry.t(), Relocation.t(), VirtualMachine.t(), [Host.t()]) ::
          atom()
  def advance_locked!(retry, r, vm, hosts) do
    host = Enum.find(hosts, &(&1.id == r.destination_host_id))

    with true <- current_stop?(retry, r, vm),
         [reservation] <- Ledger.read!(Reservation, placement_id: r.destination_placement_id),
         true <- reservation.disk_held,
         true <- RestartCapacity.fits?(host, vm, reservation) do
      needed = OverallsProtocol.VMShape.reservation(vm)
      Ledger.update!(reservation, :hold_compute, %{memory_bytes: needed.memory_bytes})

      vm =
        Ledger.intent!(vm, %{
          generation: Lifecycle.next_generation!(vm),
          desired_state: :running,
          crash_restart_times: []
        })

      operation =
        Ledger.create!(Operation, :enqueue, %{
          vm_id: vm.id,
          placement_id: vm.current_placement_id,
          execution_epoch: vm.execution_epoch,
          generation: vm.generation,
          kind: :start,
          initiator: :relocation,
          relocation_id: r.id
        })

      Ledger.update!(r, :record_retry_activation, %{
        activation_operation_id: operation.id,
        activation_generation: operation.generation
      })

      Ledger.update!(retry, :activate, %{
        start_operation_id: operation.id,
        start_generation: operation.generation,
        finished_at: Ledger.now()
      })

      :reactivating
    else
      _ -> :retry_stopping
    end
  end

  defp current_stop?(retry, r, vm) do
    with true <- vm != nil and vm.archived_at == nil and r.deletion_requested_at == nil,
         true <-
           vm.current_placement_id == r.destination_placement_id and
             vm.execution_epoch == r.destination_epoch and vm.generation == retry.stop_generation and
             vm.desired_state == :stopped and vm.observed_state == :stopped,
         [op] <- Ledger.read!(Operation, id: retry.stop_operation_id),
         true <-
           op.status == :completed and op.kind == :stop and op.initiator == :relocation and
             op.relocation_id == r.id and op.placement_id == vm.current_placement_id and
             op.execution_epoch == vm.execution_epoch and op.generation == vm.generation,
         [outcome] <- Ledger.read!(PhysicalOutcome, id: op.completion_outcome_id),
         true <- outcome.host_id == r.destination_host_id and outcome.operation_id == op.id,
         {:ok, proof} <- OverallsProtocol.Execution.outcome(outcome.observation),
         true <-
           proof.operation_id == op.id and proof.vm_id == vm.id and
             proof.placement_id == vm.current_placement_id and
             proof.execution_epoch == vm.execution_epoch and
             proof.generation == vm.generation and proof.state == :stopped and
             proof.compute_empty and proof.disk_present,
         do: true,
         else: (_ -> false)
  end
end
