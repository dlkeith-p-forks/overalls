defmodule Marshall.Compute.RelocationRestoration do
  @moduledoc "Fresh source execution authority after confirmed cancellation revocation."
  alias Marshall.Compute.{
    Host,
    Ledger,
    Lifecycle,
    Operation,
    PhysicalOutcome,
    Relocation,
    Reservation,
    VirtualMachine
  }

  # @cc [owner:ghuntley,label:security;recovery;capacity] cancelled-source-restoration-fenced
  # advance_locked!/2 requires both endpoint host locks followed by the VM lock.
  # Confirmed source revocation MUST precede an atomic fresh-epoch pause/stop.
  # Exact physical pause evidence authorizes memory-preserving resume; an
  # attempted restore MUST NOT fall back to cold boot or checkpoint replay.
  # Originally stopped or paused sources retain that state. Destination
  # unavailability MUST NOT block this path. Disk and checkpoint holds remain
  # charged until their physical cleanup evidence arrives (ADR-0198).
  # Source outcome sequence remains monotonic for its retained placement across
  # the epoch change; restoration MUST NOT reset or reuse those sequence numbers.
  # An old completed outcome MUST NOT authorize restart/completion while the
  # current source observation is unknown, failed or otherwise inconsistent.
  @spec advance_locked!(Relocation.t(), VirtualMachine.t()) :: atom()
  def advance_locked!(%{preserves_memory: true} = relocation, vm),
    do: restore_memory!(relocation, vm)

  def advance_locked!(%{original_state: :stopped, preserves_memory: false} = relocation, vm) do
    cond do
      relocation.source_restored_at != nil ->
        finish_cancelled!(relocation)

      relocation.source_revoked_at == nil ->
        :cancelling

      relocation.cancellation_stop_operation_id == nil ->
        fence!(relocation, vm)

      not current?(relocation, vm) ->
        :restoring_source

      true ->
        if vm.generation == relocation.cancellation_stop_generation and
             vm.desired_state == :stopped and vm.observed_state == :stopped and
             confirmed?(relocation, relocation.cancellation_stop_operation_id, :stop, :stopped) do
          Ledger.update!(relocation, :record_source_restored, %{source_restored_at: Ledger.now()})
          :source_restored_pending_cleanup
        else
          :restoring_source
        end
    end
  end

  def advance_locked!(_, _), do: :restoring_source

  # @cc [owner:ghuntley,label:recovery;security] cancellation-preserves-guest-memory
  # A cancelled memory move MUST fence the source at a fresh execution epoch
  # through pause, then resume that exact checkpoint only for an originally
  # running source. Capacity-wake cancellation MUST leave its source paused.
  # A failed/ambiguous consumed resume MUST NOT replay RAM or cold boot.
  @spec restore_memory!(Relocation.t(), VirtualMachine.t() | nil) :: atom()
  defp restore_memory!(relocation, vm) do
    cond do
      relocation.source_restored_at != nil ->
        finish_cancelled!(relocation)

      relocation.source_revoked_at == nil ->
        :cancelling

      vm == nil ->
        :restoring_source

      relocation.cancellation_stop_operation_id == nil ->
        fence_memory!(relocation, vm)

      not current?(relocation, vm) ->
        :restoring_source

      relocation.cancellation_start_operation_id != nil ->
        if vm.observed_state == :running and
             confirmed?(relocation, relocation.cancellation_start_operation_id, :resume, :running) do
          Ledger.update!(relocation, :record_source_restored, %{source_restored_at: Ledger.now()})
          :source_restored_pending_cleanup
        else
          :restoring_source
        end

      vm.desired_state == :paused and vm.observed_state == :paused and
          confirmed?(relocation, relocation.cancellation_stop_operation_id, :pause, :paused) ->
        if relocation.original_state == :running and relocation.wake_request_id == nil do
          resume_memory!(relocation, vm)
        else
          Ledger.update!(relocation, :record_source_restored, %{source_restored_at: Ledger.now()})
          :source_restored_pending_cleanup
        end

      true ->
        :restoring_source
    end
  end

  @spec fence_memory!(Relocation.t(), VirtualMachine.t()) :: atom()
  defp fence_memory!(relocation, vm) do
    if vm.current_placement_id == relocation.source_placement_id and
         vm.execution_epoch == relocation.source_epoch do
      Lifecycle.cancel_operations!(vm.id)

      vm =
        Ledger.update!(vm, :restore_source, %{
          execution_epoch: relocation.destination_epoch,
          generation: Lifecycle.next_generation!(vm),
          desired_state: :paused,
          observed_state: :pending,
          observed_at: nil,
          failure_reason: nil
        })

      operation = enqueue!(relocation, vm, :pause)

      Ledger.update!(relocation, :record_cancellation_stop, %{
        cancellation_stop_operation_id: operation.id,
        cancellation_stop_generation: operation.generation
      })
    end

    :restoring_source
  end

  @spec resume_memory!(Relocation.t(), VirtualMachine.t()) :: atom()
  defp resume_memory!(relocation, vm) do
    [host] = Ledger.read!(Host, id: vm.host_id)
    [reservation] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)

    if Marshall.Compute.RestartCapacity.check_source_restoration(
         host,
         vm,
         reservation,
         relocation
       ) == :fits do
      Ledger.update!(reservation, :hold_compute, %{memory_bytes: reservation.memory_bytes})

      vm =
        Ledger.intent!(vm, %{generation: Lifecycle.next_generation!(vm), desired_state: :running})

      operation = enqueue!(relocation, vm, :resume)

      Ledger.update!(relocation, :record_cancellation_start, %{
        cancellation_start_operation_id: operation.id,
        cancellation_start_generation: operation.generation
      })
    end

    :restoring_source
  end

  # @cc [owner:ghuntley,label:capacity;recovery] cancellation-completes-after-independent-cleanup
  # Under both host locks and the VM lock, cancellation MUST retain destination
  # commitments until confirmed destination reclamation, source snapshot cleanup
  # and both stream revocations. Source restoration must already be recorded.
  # Completion releases only destination reservations, preserving authoritative
  # source disk/compute, VM identity and address. Released slots retain history.
  defp finish_cancelled!(relocation) do
    if relocation.source_snapshots_cleaned_at != nil and relocation.destination_cleaned_at != nil and
         relocation.source_revoked_at != nil and relocation.destination_revoked_at != nil do
      [destination] = Ledger.read!(Reservation, placement_id: relocation.destination_placement_id)
      Ledger.update!(destination, :release_all, %{})
      Ledger.update!(relocation, :finish_cancellation, %{finished_at: Ledger.now()})
      :cancelled
    else
      :source_restored_pending_cleanup
    end
  end

  defp fence!(relocation, vm) do
    with true <- vm != nil and vm.archived_at == nil and vm.desired_state == :stopped,
         true <-
           vm.current_placement_id == relocation.source_placement_id and
             vm.execution_epoch == relocation.source_epoch,
         [%{disk_held: true}] <-
           Ledger.read!(Reservation, placement_id: relocation.source_placement_id) do
      Lifecycle.cancel_operations!(vm.id)

      vm =
        Ledger.update!(vm, :restore_source, %{
          execution_epoch: relocation.destination_epoch,
          generation: Lifecycle.next_generation!(vm),
          desired_state: :stopped,
          observed_state: :pending,
          observed_at: nil,
          failure_reason: nil
        })

      operation = enqueue!(relocation, vm, :stop)

      Ledger.update!(relocation, :record_cancellation_stop, %{
        cancellation_stop_operation_id: operation.id,
        cancellation_stop_generation: operation.generation
      })
    end

    :restoring_source
  end

  defp enqueue!(relocation, vm, kind),
    do:
      Ledger.create!(Operation, :enqueue, %{
        vm_id: vm.id,
        placement_id: relocation.source_placement_id,
        execution_epoch: vm.execution_epoch,
        generation: vm.generation,
        kind: kind,
        initiator: :relocation,
        relocation_id: relocation.id
      })

  defp current?(relocation, vm),
    do:
      vm != nil and vm.archived_at == nil and
        vm.current_placement_id == relocation.source_placement_id and
        vm.execution_epoch == relocation.destination_epoch

  defp confirmed?(relocation, id, kind, state) do
    with [%{status: :completed, kind: ^kind} = operation] <- Ledger.read!(Operation, id: id),
         true <-
           operation.relocation_id == relocation.id and operation.vm_id == relocation.vm_id and
             operation.placement_id == relocation.source_placement_id and
             operation.execution_epoch == relocation.destination_epoch,
         [outcome] <- Ledger.read!(PhysicalOutcome, id: operation.completion_outcome_id),
         {:ok, physical} <- OverallsProtocol.Execution.outcome(outcome.observation),
         true <-
           outcome.host_id == relocation.source_host_id and physical.operation_id == operation.id and
             physical.vm_id == operation.vm_id and physical.placement_id == operation.placement_id and
             physical.execution_epoch == operation.execution_epoch and
             physical.generation == operation.generation and
             physical.state == state and physical.disk_present and not physical.cleanup_complete and
             physical.compute_empty == state in [:stopped, :paused],
         do: true,
         else: (_ -> false)
  end
end
