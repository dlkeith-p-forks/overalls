defmodule Marshall.Compute.RelocationCoordinator do
  @moduledoc "Durable relocation transitions with sorted endpoint locks and physical evidence."
  alias Marshall.Compute.{
    Host,
    Ledger,
    Lifecycle,
    Operation,
    PhysicalOutcome,
    Relocation,
    RelocationReceives,
    Reservation,
    TransferSlot,
    VirtualMachine
  }

  require Marshall.Events

  # @cc [owner:ghuntley,label:concurrency;capacity;recovery] relocation-stop-atomic-fence
  # advance/1 MUST lock both endpoint hosts in UUID order before the VM. Pausing
  # a running source requires fresh authenticated destination connectivity proof,
  # fresh ready/image-capable endpoints and all original commitments/slots; that
  # probe reference, pause generation, console fence, operation/job and relocation
  # reference MUST commit together exactly once. No disk is copied before the
  # recorded physical pause. Accepted cancellation MUST prevent further
  # pause/handoff transitions. Source compute/disk MUST remain held until the
  # handoff for cancellation.
  @spec advance(String.t()) :: {:ok, atom()} | {:error, term()}
  def advance(id) do
    result =
      Ledger.transaction(fn ->
        case Ledger.read!(Relocation, id: id) do
          [relocation] ->
            hosts =
              [relocation.source_host_id, relocation.destination_host_id]
              |> Enum.sort()
              |> Enum.map(&Ledger.lock!(Host, &1))

            vm = Ledger.lock!(VirtualMachine, relocation.vm_id)
            [relocation] = Ledger.read!(Relocation, id: id)
            step(relocation, vm, hosts)

          [] ->
            :absent
        end
      end)

    case result do
      {:ok, {:stop_enqueued, events}} ->
        emit_pending(events)
        {:ok, :stopping}

      {:ok, {:handoff_committed, events}} ->
        emit_pending(events)
        {:ok, :committed}

      {:ok, step} ->
        {:ok, step}

      error ->
        error
    end
  end

  defp emit_pending(events) do
    unless Marshall.Repo.in_transaction?() do
      Enum.each(events, fn
        {:stop_enqueued, relocation_id, vm_id, operation_id} ->
          Marshall.Events.emit("relocation.stop_enqueued",
            relocation_id: relocation_id,
            vm_id: vm_id,
            operation_id: operation_id
          )

        {:handoff_committed, relocation_id, vm_id, host_id, placement_id, execution_epoch,
         generation} ->
          Marshall.Events.emit("relocation.handoff_committed",
            relocation_id: relocation_id,
            vm_id: vm_id,
            host_id: host_id,
            placement_id: placement_id,
            execution_epoch: execution_epoch,
            generation: generation
          )
      end)
    end

    :ok
  end

  defp step(%{finished_at: finished}, _, _) when not is_nil(finished), do: :finished

  defp step(%{deletion_requested_at: requested} = relocation, vm, _)
       when not is_nil(requested) do
    release_quiescent_streams!(relocation)
    Marshall.Compute.RelocationDeletion.advance_locked!(relocation, vm)
  end

  defp step(%{cancellation_requested_at: requested} = relocation, vm, _)
       when not is_nil(requested) do
    release_quiescent_streams!(relocation)
    Marshall.Compute.RelocationRestoration.advance_locked!(relocation, vm)
  end

  defp step(%{committed_at: committed} = relocation, vm, _) when not is_nil(committed) do
    release_quiescent_streams!(relocation)
    Marshall.Compute.RelocationReadinessState.advance_locked!(relocation, vm)
    Marshall.Compute.RelocationCleanup.advance_locked!(relocation, vm)
    :committed
  end

  defp step(relocation, %{desired_state: :paused, observed_state: :paused} = vm, hosts),
    do: handoff(relocation, vm, hosts)

  defp step(relocation, %{desired_state: :stopped} = vm, hosts),
    do: handoff(relocation, vm, hosts)

  defp step(%{source_stop_operation_id: id}, _, _) when not is_nil(id), do: :stopping

  defp step(%{original_state: :running} = relocation, vm, hosts) do
    now = Ledger.now()
    probe = if vm != nil, do: Marshall.Compute.RelocationProbes.ready_request(relocation, vm, now)

    if probe != nil and vm.archived_at == nil and vm.desired_state == :running and
         vm.observed_state == :running and
         vm.current_placement_id == relocation.source_placement_id and
         vm.execution_epoch == relocation.source_epoch and
         Enum.all?(hosts, fn host ->
           if host.id == relocation.source_host_id,
             do: source_ready?(host, vm, now, relocation),
             else: ready?(host, vm, now)
         end) and
         Enum.find(hosts, &(&1.id == relocation.source_host_id)).transfer_endpoint ==
           relocation.source_endpoint and
         held?(relocation) and
         Enum.all?(
           Ledger.read!(Operation, vm_id: vm.id),
           &(&1.status not in [:pending, :acknowledged])
         ) do
      vm =
        Ledger.intent!(vm, %{
          generation: Lifecycle.next_generation!(vm),
          desired_state: :paused
        })

      operation =
        Ledger.create!(Operation, :enqueue, %{
          vm_id: vm.id,
          placement_id: relocation.source_placement_id,
          execution_epoch: relocation.source_epoch,
          generation: vm.generation,
          kind: :pause,
          initiator: :relocation,
          relocation_id: relocation.id
        })

      Ledger.update!(relocation, :record_stop, %{
        source_stop_operation_id: operation.id,
        source_stop_generation: operation.generation,
        source_preflight_request_id: probe.id
      })

      {:stop_enqueued, [{:stop_enqueued, relocation.id, vm.id, operation.id}]}
    else
      :waiting
    end
  end

  defp step(_, _, _), do: :waiting

  # @cc [owner:ghuntley,label:recovery;capacity;concurrency] relocation-handoff-and-activation-atomic
  # Handoff MUST require matching final adoption evidence and quiescent source
  # authority under both host locks and the VM lock. New placement/epoch, generation,
  # reset observation sequence, commit references and activation outbox commit
  # atomically once. Release only source compute; retain both disks and source
  # snapshots until readiness and cleanup.
  # Originally stopped workloads receive stop activation; paused workloads stay
  # paused. Running memory-bearing moves MUST resume the exact checkpoint.
  defp handoff(relocation, vm, hosts) do
    waiting = if relocation.source_stop_operation_id, do: :stopping, else: :waiting
    destination = Enum.find(hosts, &(&1.id == relocation.destination_host_id))

    with %{destination_imported_at: imported} = receipt when not is_nil(imported) <-
           RelocationReceives.final_received(relocation, vm),
         true <- ready?(destination, vm, Ledger.now()),
         [source] <- Ledger.read!(Reservation, placement_id: relocation.source_placement_id),
         [target] <- Ledger.read!(Reservation, placement_id: relocation.destination_placement_id),
         true <- target.compute_held == (relocation.original_state == :running),
         true <-
           relocation.original_state != :running or
             Marshall.Compute.RestartCapacity.fits?(destination, vm, target),
         true <-
           Enum.all?(
             Ledger.read!(Operation, vm_id: vm.id),
             &(&1.status not in [:pending, :acknowledged])
           ) do
      vm =
        Ledger.update!(vm, :handoff, %{
          current_placement_id: relocation.destination_placement_id,
          execution_epoch: relocation.destination_epoch,
          generation: Lifecycle.next_generation!(vm),
          desired_state: relocation.original_state,
          observed_state: :pending,
          outcome_sequence: 0,
          observed_at: nil,
          failure_reason: nil
        })

      operation =
        Ledger.create!(Operation, :enqueue, %{
          vm_id: vm.id,
          placement_id: relocation.destination_placement_id,
          execution_epoch: relocation.destination_epoch,
          generation: vm.generation,
          kind: activation_kind(relocation),
          initiator: :relocation,
          relocation_id: relocation.id
        })

      Ledger.update!(relocation, :record_commit, %{
        committed_at: Ledger.now(),
        import_request_id: receipt.id,
        activation_operation_id: operation.id,
        activation_generation: operation.generation
      })

      Ledger.update!(source, :release_compute, %{})

      {:handoff_committed,
       [
         {:handoff_committed, relocation.id, vm.id, relocation.destination_host_id,
          vm.current_placement_id, vm.execution_epoch, vm.generation}
       ]}
    else
      _ -> waiting
    end
  end

  # @cc [owner:ghuntley,label:capacity;recovery] stream-slots-require-both-receipts
  # Under both endpoint host locks, cancelled or committed moves release occupancy only
  # after independent source revocation and destination quiescence receipts. Disk
  # cleanup and source restoration may remain pending; neither grants or withholds
  # this stream-only release. Retries MUST preserve the first release timestamps.
  defp release_quiescent_streams!(relocation) do
    if relocation.source_revoked_at != nil and relocation.destination_revoked_at != nil do
      for endpoint <- [:source_relocation_id, :destination_relocation_id],
          slot <- Ledger.read!(TransferSlot, [{endpoint, relocation.id}]),
          slot.released_at == nil do
        Ledger.update!(slot, :release, %{released_at: Ledger.now()})
      end
    end

    :ok
  end

  defp source_ready?(host, vm, now, relocation),
    do:
      Marshall.Compute.Evacuations.source_allowed?(host, relocation) and
        host.architecture == vm.architecture and
        host.inventory["execution_ready"] == true and
        (vm.current_checkpoint == nil or
           host.inventory["checkpoint_compatibility"] == vm.current_checkpoint["compatibility"]) and
        Marshall.Compute.HostLiveness.capacity_fresh?(host.reported_at, now)

  @spec activation_kind(Relocation.t()) :: :stop | :pause | :resume
  def activation_kind(%{original_state: :running, preserves_memory: true}), do: :resume
  def activation_kind(%{original_state: :paused}), do: :pause
  def activation_kind(%{original_state: :stopped}), do: :stop

  defp ready?(nil, _, _), do: false

  defp ready?(host, vm, now),
    do:
      host.enabled and host.maintenance_mode == :normal and
        host.architecture == vm.architecture and
        host.inventory["execution_ready"] == true and
        (vm.current_checkpoint == nil or
           host.inventory["checkpoint_compatibility"] == vm.current_checkpoint["compatibility"]) and
        Marshall.Compute.HostLiveness.capacity_fresh?(host.reported_at, now)

  defp held?(relocation) do
    Enum.all?([relocation.source_placement_id, relocation.destination_placement_id], fn id ->
      match?(
        [%{disk_held: true, compute_held: true}],
        Ledger.read!(Reservation, placement_id: id)
      )
    end) and
      match?(
        [%{released_at: nil}],
        Ledger.read!(TransferSlot, source_relocation_id: relocation.id)
      ) and
      match?(
        [%{released_at: nil}],
        Ledger.read!(TransferSlot, destination_relocation_id: relocation.id)
      )
  end

  # @cc [owner:ghuntley,label:recovery;security] final-stream-requires-recorded-physical-stop
  # stop_confirmed?/2 requires current VM serialization. Neither pause intent,
  # acknowledgement nor status alone suffices: the exact relocation operation
  # must retain a matching immutable paused outcome with compute empty and disk
  # present. Placement/epoch/generation must still identify the same source.
  @spec stop_confirmed?(Relocation.t(), VirtualMachine.t()) :: boolean()
  def stop_confirmed?(relocation, vm) do
    with true <- relocation.source_stop_operation_id != nil and vm != nil,
         true <-
           vm.current_placement_id == relocation.source_placement_id and
             vm.execution_epoch == relocation.source_epoch and
             vm.generation == relocation.source_stop_generation and vm.desired_state == :paused and
             vm.observed_state == :paused,
         [operation] <- Ledger.read!(Operation, id: relocation.source_stop_operation_id),
         true <-
           operation.status == :completed and operation.kind == :pause and
             operation.initiator == :relocation and
             operation.relocation_id == relocation.id and
             operation.placement_id == relocation.source_placement_id and
             operation.execution_epoch == relocation.source_epoch and
             operation.generation == vm.generation and operation.completion_outcome_id != nil,
         [outcome] <- Ledger.read!(PhysicalOutcome, id: operation.completion_outcome_id),
         true <-
           outcome.host_id == relocation.source_host_id and outcome.operation_id == operation.id,
         {:ok, observation} <- OverallsProtocol.Execution.outcome(outcome.observation),
         true <-
           observation.operation_id == operation.id and observation.vm_id == vm.id and
             observation.placement_id == operation.placement_id and
             observation.execution_epoch == operation.execution_epoch and
             observation.generation == operation.generation and observation.state == :paused and
             observation.compute_empty and observation.disk_present,
         do: true,
         else: (_ -> false)
  end
end
