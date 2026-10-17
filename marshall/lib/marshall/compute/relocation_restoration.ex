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
  # Confirmed source revocation MUST precede an atomic fresh-epoch stop/outbox.
  # Only its exact physical stopped outcome may authorize restart of an originally
  # running source. Originally stopped sources MUST remain stopped. Destination
  # unavailability MUST NOT block this path. Copy holds remain charged; relocations
  # hold no temporary headroom (ADR-0155), so source snapshot cleanup frees none.
  # Source outcome sequence remains monotonic for its retained placement across
  # the epoch change; restoration MUST NOT reset or reuse those sequence numbers.
  # An old completed outcome MUST NOT authorize restart/completion while the
  # current source observation is unknown, failed or otherwise inconsistent.
  @spec advance_locked!(Relocation.t(), VirtualMachine.t()) :: atom()
  def advance_locked!(relocation, vm) do
    cond do
      relocation.source_restored_at != nil ->
        finish_cancelled!(relocation)

      relocation.source_revoked_at == nil ->
        :cancelling

      relocation.cancellation_stop_operation_id == nil ->
        fence!(relocation, vm)

      not current?(relocation, vm) ->
        :restoring_source

      relocation.original_state == :stopped ->
        if vm.generation == relocation.cancellation_stop_generation and
             vm.desired_state == :stopped and vm.observed_state == :stopped and
             confirmed?(relocation, relocation.cancellation_stop_operation_id, :stop, :stopped) do
          Ledger.update!(relocation, :record_source_restored, %{source_restored_at: Ledger.now()})
          :source_restored_pending_cleanup
        else
          :restoring_source
        end

      relocation.cancellation_start_operation_id == nil ->
        restart!(relocation, vm)

      failed_start?(relocation, vm) ->
        retry_stop!(relocation, vm)

      vm.generation == relocation.cancellation_start_generation and vm.desired_state == :running and
        vm.observed_state == :running and
          confirmed?(relocation, relocation.cancellation_start_operation_id, :start, :running) ->
        Ledger.update!(relocation, :record_source_restored, %{source_restored_at: Ledger.now()})
        :source_restored_pending_cleanup

      true ->
        :restoring_source
    end
  end

  # @cc [owner:ghuntley,label:recovery;capacity] restoration-retry-fences-and-bounds-attempts
  # Under both host locks and the VM lock, an exact current failed-start receipt
  # may schedule at most three retry cycles per ten minutes, charging future
  # timestamps conservatively. Each cycle MUST atomically retain all reservations,
  # advance generation to stopped intent, enqueue a fresh stop and clear the prior
  # start reference. Only the new stop's physical proof may authorize another start.
  # Unknown/stale outcomes or missing disks MUST NOT trigger this retry. Exhaustion
  # retains the restoration obligation and holds; it never marks cancellation done.
  defp retry_stop!(relocation, vm) do
    now = Ledger.now()

    attempts =
      Enum.filter(vm.crash_restart_times, &(DateTime.diff(now, &1, :microsecond) < 600_000_000))

    [host] = Ledger.read!(Host, id: relocation.source_host_id)

    cond do
      length(attempts) >= 3 ->
        :restoration_retry_exhausted

      not Marshall.Compute.Evacuations.source_allowed?(host, relocation) ->
        :restoring_source

      true ->
        Lifecycle.cancel_operations!(vm.id)

        vm =
          Ledger.intent!(vm, %{
            generation: Lifecycle.next_generation!(vm),
            desired_state: :stopped,
            crash_restart_times: attempts ++ [now]
          })

        stop = enqueue!(relocation, vm, :stop)

        Ledger.update!(relocation, :record_cancellation_stop, %{
          cancellation_stop_operation_id: stop.id,
          cancellation_stop_generation: stop.generation,
          cancellation_start_operation_id: nil,
          cancellation_start_generation: nil
        })

        :restoring_source
    end
  end

  defp failed_start?(relocation, vm) do
    with true <-
           vm.desired_state == :running and vm.observed_state == :failed and
             vm.generation == relocation.cancellation_start_generation,
         [operation] <- Ledger.read!(Operation, id: relocation.cancellation_start_operation_id),
         true <-
           operation.status == :completed and operation.kind == :start and
             operation.initiator == :relocation and
             operation.vm_id == vm.id and
             operation.relocation_id == relocation.id and
             operation.placement_id == vm.current_placement_id and
             operation.execution_epoch == vm.execution_epoch and
             operation.generation == vm.generation,
         [outcome] <-
           Ledger.read!(PhysicalOutcome,
             placement_id: vm.current_placement_id,
             sequence: vm.outcome_sequence
           ),
         true <-
           outcome.host_id == relocation.source_host_id and outcome.operation_id == operation.id,
         {:ok, physical} <- OverallsProtocol.Execution.outcome(outcome.observation),
         true <-
           physical.operation_id == operation.id and physical.vm_id == vm.id and
             physical.sequence == vm.outcome_sequence and
             physical.placement_id == vm.current_placement_id and
             physical.execution_epoch == vm.execution_epoch and
             physical.generation == vm.generation and physical.state == :failed and
             physical.compute_empty and
             physical.disk_present and not physical.cleanup_complete,
         do: true,
         else: (_ -> false)
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
    with true <- vm != nil and vm.archived_at == nil and vm.desired_state in [:running, :stopped],
         true <-
           vm.current_placement_id == relocation.source_placement_id and
             vm.execution_epoch == relocation.source_epoch,
         [%{disk_held: true} = hold] <-
           Ledger.read!(Reservation, placement_id: relocation.source_placement_id),
         true <- relocation.original_state == :stopped or hold.compute_held do
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

  defp restart!(relocation, vm) do
    if vm.generation == relocation.cancellation_stop_generation and vm.desired_state == :stopped and
         vm.observed_state == :stopped and
         confirmed?(relocation, relocation.cancellation_stop_operation_id, :stop, :stopped) do
      vm =
        Ledger.intent!(vm, %{
          generation: Lifecycle.next_generation!(vm),
          desired_state: :running
        })

      operation = enqueue!(relocation, vm, :start)

      Ledger.update!(relocation, :record_cancellation_start, %{
        cancellation_start_operation_id: operation.id,
        cancellation_start_generation: operation.generation
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
             physical.compute_empty == (state == :stopped),
         do: true,
         else: (_ -> false)
  end
end
