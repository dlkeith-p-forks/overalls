defmodule Marshall.Compute.Outcomes do
  @moduledoc "Apply authenticated physical observations, retaining allocations for stale or unknown effects."
  alias OverallsProtocol.Execution
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    CommandSnapshot,
    Host,
    Ledger,
    Lifecycle,
    NetworkAddress,
    Operation,
    PhysicalOutcome,
    RelocationGuard,
    Reservation,
    VirtualMachine,
    WorkloadPlacement
  }

  require Ash.Query

  @type transition ::
          {:resize_phase, String.t(), atom()}
          | {:resize_finished, String.t(), String.t()}
          | {:resize_failed, String.t(), atom()}
          | {:resize_cancelled, String.t(), String.t()}
          | {:recovery_restarted, String.t(), String.t()}

  @typep event :: Execution.outcome() | transition()

  # @cc [owner:ghuntley,label:recovery] outcomes-replay-identity
  # The authenticated host-locked transaction MUST accept an outcome ID replay
  # only when its host and full encoded observation match. A changed replay or
  # reused placement sequence MUST roll back the exchange.
  @doc "Called only inside the authenticated host transaction."
  @spec ingest_locked!(String.t(), [Execution.outcome()]) :: [String.t()]
  def ingest_locked!(host_id, outcomes) do
    {accepted, _events} = ingest_with_events_locked!(host_id, outcomes)
    accepted
  end

  @doc "Returns newly recorded outcomes and transitions for logging only after the outer transaction commits."
  @spec ingest_with_events_locked!(String.t(), [Execution.outcome()]) ::
          {[String.t()], [event()]}
  def ingest_with_events_locked!(host_id, outcomes) do
    {accepted, events} =
      Enum.map_reduce(outcomes, [], fn outcome, events ->
        encoded = Execution.encode_outcome(outcome)

        events =
          case Ledger.read!(PhysicalOutcome, id: outcome.id) do
            [previous] ->
              unless previous.host_id == host_id and previous.observation == encoded,
                do: Ledger.rollback(:outcome_conflict)

              events

            [] ->
              transitions = record!(host_id, outcome, encoded)
              events ++ [outcome | transitions]
          end

        {outcome.id, events}
      end)

    {accepted, events}
  end

  # @cc [owner:ghuntley,label:recovery] outcomes-current-generation-only
  # An observation MUST match its immutable operation's host, VM and generation/kind
  # before recording. Only a newer sequence for the current placement, execution
  # epoch and live VM generation may
  # change state; stale valid observations remain recorded without undoing newer
  # intent, and future generations MUST be rejected. A matching recorded source
  # cleanup delete may complete its operation without mutating destination state;
  # capacity remains held for the relocation coordinator.
  # A running resume MUST carry the exact immutable commanded checkpoint;
  # omitted continuation evidence MUST NOT complete a resume or grant readiness.
  defp record!(host_id, outcome, encoded) do
    vm =
      VirtualMachine
      |> Ash.Query.for_read(:history, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(id == ^outcome.vm_id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(actor: SystemActor.compute())

    unless vm != nil, do: Ledger.rollback(:invalid_outcome)

    operation =
      case Ledger.read!(Operation, id: outcome.operation_id) do
        [%{vm_id: id, generation: generation, kind: kind} = operation]
        when id == vm.id and generation == outcome.generation ->
          unless operation.placement_id == outcome.placement_id and
                   operation.execution_epoch == outcome.execution_epoch,
                 do: Ledger.rollback(:invalid_outcome)

          unless compatible?(kind, outcome.state), do: Ledger.rollback(:invalid_outcome)

          if kind == :resume do
            case Map.fetch(outcome, :checkpoint) do
              {:ok, checkpoint} ->
                unless OverallsProtocol.Checkpoint.encode(checkpoint) ==
                         operation.command_snapshot["checkpoint"],
                       do: Ledger.rollback(:invalid_outcome)

              :error ->
                if outcome.state == :running, do: Ledger.rollback(:invalid_outcome)
            end
          end

          if kind == :pause and Map.has_key?(outcome, :checkpoint) and
               outcome.checkpoint.memory_bytes != operation.command_snapshot["memory_bytes"],
             do: Ledger.rollback(:invalid_outcome)

          if Map.get(outcome, :guest_ready) == true and kind not in [:provision, :start, :resume],
            do: Ledger.rollback(:invalid_outcome)

          operation

        _ ->
          Ledger.rollback(:invalid_outcome)
      end

    # Validate resize evidence even when its generation is stale; stale history
    # cannot introduce a different physical shape under an immutable command.
    if operation.kind == :resize and outcome.state == :stopped do
      unless outcome.disk_present and
               Map.get(outcome, :applied_sizes) ==
                 Map.take(operation.command_snapshot, ["vcpu", "memory_bytes", "disk_bytes"]),
             do: Ledger.rollback(:invalid_outcome)
    else
      if Map.has_key?(outcome, :applied_sizes), do: Ledger.rollback(:invalid_outcome)
    end

    case Ledger.read!(WorkloadPlacement, id: operation.placement_id) do
      [%{host_id: ^host_id}] -> :ok
      _ -> Ledger.rollback(:invalid_outcome)
    end

    if outcome.generation > vm.generation, do: Ledger.rollback(:invalid_outcome)

    if Ledger.read!(PhysicalOutcome,
         placement_id: operation.placement_id,
         sequence: outcome.sequence
       ) != [],
       do: Ledger.rollback(:outcome_conflict)

    Ledger.create!(PhysicalOutcome, :record, %{
      id: outcome.id,
      host_id: host_id,
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: outcome.operation_id,
      generation: outcome.generation,
      sequence: outcome.sequence,
      observation: encoded
    })

    if Marshall.Compute.RelocationCleanup.operation_allowed?(operation) and
         outcome.state == :deleted and outcome.compute_empty and not outcome.disk_present and
         outcome.cleanup_complete do
      complete!(operation, outcome)
    end

    if vm.archived_at == nil and vm.current_placement_id == operation.placement_id and
         vm.execution_epoch == operation.execution_epoch and outcome.generation == vm.generation and
         outcome.sequence > vm.outcome_sequence do
      if operation.resize_request_id do
        case Marshall.Compute.Resize.outcome_locked!(vm, operation, outcome) do
          :ordinary -> apply!(vm, outcome)
          {:ok, transitions} -> transitions
        end
      else
        apply!(vm, outcome)
      end
    else
      []
    end
  end

  # @cc [owner:ghuntley,label:capacity] outcomes-release-requires-physical-result
  # Unknown outcomes MUST retain allocations. Matching stopped outcomes release
  # current-placement compute outside relocation or after retained restoration/
  # readiness permits ordinary lifecycle. Unresolved relocation retains holds for
  # its coordinator. Matching ordinary deletion releases its copy only outside
  # unfinished relocation; address release and archival require every placement's
  # commitments reclaimed. Ordinary failed starts may release compute but MUST
  # retain disk and address. Independent copy-cleanup holds remain untouched.

  # @cc [owner:ghuntley,label:recovery] relocation-outcomes-do-not-restart
  # Current failure evidence during unresolved relocation/restoration MUST update observed
  # state and be acknowledged without issuing recovery starts, changing execution
  # authority or releasing commitments. Once source restoration or destination
  # readiness is retained, ordinary lifecycle recovery and compute release apply
  # on that authoritative placement while independent cleanup remains pending.
  @spec apply!(VirtualMachine.t(), Execution.outcome()) :: [transition()]
  defp apply!(vm, outcome) do
    :ok
    [reservation] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)

    if outcome.state == :running and not reservation.compute_held,
      do: Ledger.rollback(:outcome_conflict)

    vm =
      Ledger.update!(vm, :observe, %{
        observed_state: outcome.state,
        observed_at: Ledger.now(),
        outcome_sequence: outcome.sequence,
        failure_reason: if(outcome.reason == :none, do: nil, else: outcome.reason)
      })

    [operation] = Ledger.read!(Operation, id: outcome.operation_id)

    if Map.has_key?(outcome, :checkpoint) do
      Ledger.update!(vm, :checkpoint, %{
        current_checkpoint: OverallsProtocol.Checkpoint.encode(outcome.checkpoint)
      })
    end

    record_activation_phase(operation, outcome)

    if operation.clone_request_id do
      case Ledger.read!(Marshall.Compute.CloneRequest,
             id: operation.clone_request_id,
             active: true
           ) do
        [request] -> Ledger.update!(request, :schedule, %{})
        [] -> :ok
      end
    end

    relocating = RelocationGuard.lifecycle_busy?(vm, operation.kind)

    case {vm.desired_state, operation.kind, outcome.state} do
      {:running, kind, :running} when kind in [:provision, :start, :resume] ->
        complete!(operation, outcome)
        []

      {:paused, :pause, :paused} ->
        if relocating and reservation.compute_held do
          Ledger.update!(reservation, :hold_compute, %{memory_bytes: reservation.memory_bytes})
        else
          Ledger.update!(reservation, :release_compute, %{})
        end

        complete!(operation, outcome)
        Ledger.after_commit(fn -> Marshall.MessageBoards.purge_for_state!(vm.id, :paused) end)
        []

      {:paused, :pause, :failed} ->
        complete!(operation, outcome)
        []

      {:stopped, :stop, :stopped} ->
        Ledger.update!(vm, :checkpoint, %{current_checkpoint: nil})
        Ledger.update!(reservation, :release_checkpoint, %{})
        unless relocating, do: Ledger.update!(reservation, :release_compute, %{})
        complete!(operation, outcome)
        Ledger.after_commit(fn -> Marshall.MessageBoards.purge_for_state!(vm.id, :stopped) end)
        []

      {:deleted, :delete, :deleted} ->
        unless relocating, do: Ledger.update!(reservation, :release_all, %{})
        complete!(operation, outcome)

        if not relocating and all_reclaimed?(vm.id) do
          for address <- Ledger.read!(NetworkAddress, vm_id: vm.id),
              do: Ledger.archive!(address, :release)

          # Remaining pins belong to non-owners or a retired owner (ADR-0193).
          Marshall.Access.Pins.remove_for_vm!(vm.id)
          Ledger.archive!(vm, :archive)
        end

        []

      {:running, kind, :failed} when kind in [:provision, :start, :resume] ->
        cond do
          relocating ->
            complete!(operation, outcome)
            []

          operation.kind != :resume and vm.current_checkpoint == nil and
            outcome.reason == :crashed and reservation.compute_held ->
            recover!(vm, operation, reservation, outcome)

          true ->
            fail!(operation, reservation, outcome)
            []
        end

      _ ->
        []
    end
  end

  # @cc [owner:ghuntley,label:recovery] outcomes-bounded-crash-recovery
  # Automatic crash recovery MUST allow at most three starts per ten-minute
  # window and none while the host is draining/retired. Future attempt timestamps
  # MUST remain charged if the database clock moves backward; exhausted recovery
  # or unavailable physical headroom releases compute while retaining disk and address.
  # An unavailable durable source capability MUST also refuse restart while
  # committing the confirmed crash/report and releasing only proven compute.
  @spec recover!(VirtualMachine.t(), Operation.t(), Reservation.t(), Execution.outcome()) ::
          [transition()]
  defp recover!(vm, operation, reservation, outcome) do
    [host] = Ledger.read!(Host, id: vm.host_id)
    now = Ledger.now()
    # Keep future timestamps conservatively if the database clock moves backward.
    # Dropping them could turn a clock adjustment into an unlimited restart budget.
    attempts =
      Enum.filter(vm.crash_restart_times, &(DateTime.diff(now, &1, :microsecond) < 600_000_000))

    complete!(operation, outcome)
    recovery_decision!(host, vm, reservation, attempts, now)
  end

  # @cc [owner:ghuntley,label:capacity;recovery] crash-recovery-waits-for-fresh-capacity
  # Within the three-per-ten-minutes budget, a crashed VM restarts only when
  # fresh telemetry shows it fits. Telemetry that is merely too old MUST NOT
  # end recovery: the compute hold stays and resume_recoveries_locked!/1
  # re-decides on the host's next accepted report. An exhausted budget or a
  # measured shortfall releases compute (disk and address are retained).
  defp recovery_decision!(host, vm, reservation, attempts, now) do
    capacity =
      cond do
        not CommandSnapshot.workspace_source_available?(vm) -> :source_unavailable
        length(attempts) < 3 -> Marshall.Compute.RestartCapacity.check(host, vm, reservation)
        true -> :exhausted
      end

    case capacity do
      :fits -> restart_after_crash!(vm, reservation, attempts, now)
      :stale -> []
      _ -> release_after_crash!(reservation)
    end
  end

  defp release_after_crash!(reservation) do
    Ledger.update!(reservation, :release_compute, %{})
    []
  end

  @doc """
  Trusted coordinator only: caller holds the host row lock in a ledger
  transaction and has just accepted a fresh report. Restarts this host's
  crashed VMs whose recovery awaited fresh capacity telemetry.
  """
  @spec resume_recoveries_locked!(Host.t()) :: [transition()]
  def resume_recoveries_locked!(host) do
    now = Ledger.now()

    Ledger.read!(VirtualMachine,
      host_id: host.id,
      desired_state: :running,
      observed_state: :failed,
      failure_reason: :crashed,
      archived_at: [is_nil: true]
    )
    |> Enum.flat_map(fn candidate ->
      vm = Ledger.lock!(VirtualMachine, candidate.id)

      with true <- vm.desired_state == :running and vm.observed_state == :failed,
           [] <- Ledger.read!(Operation, vm_id: vm.id, status: [in: [:pending, :acknowledged]]),
           [reservation] <- Ledger.read!(Reservation, placement_id: vm.current_placement_id),
           true <- reservation.compute_held do
        attempts =
          Enum.filter(
            vm.crash_restart_times,
            &(DateTime.diff(now, &1, :microsecond) < 600_000_000)
          )

        recovery_decision!(host, vm, reservation, attempts, now)
      else
        _ -> []
      end
    end)
  end

  defp restart_after_crash!(vm, reservation, attempts, now) do
    needed = OverallsProtocol.VMShape.reservation(vm)
    Ledger.update!(reservation, :hold_compute, %{memory_bytes: needed.memory_bytes})
    Lifecycle.cancel_operations!(vm.id)

    vm =
      Ledger.intent!(vm, %{
        generation: Lifecycle.next_generation!(vm),
        desired_state: :running,
        crash_restart_times: attempts ++ [now]
      })

    restart =
      Ledger.create!(Operation, :enqueue, %{
        placement_id: vm.current_placement_id,
        execution_epoch: vm.execution_epoch,
        vm_id: vm.id,
        generation: vm.generation,
        initiator: :recovery,
        kind: :start
      })

    [{:recovery_restarted, vm.id, restart.id}]
  end

  defp fail!(operation, reservation, outcome) do
    complete!(operation, outcome)
    Ledger.update!(reservation, :release_compute, %{})
  end

  defp all_reclaimed?(vm_id) do
    Enum.all?(Ledger.read!(Reservation, vm_id: vm_id), fn reservation ->
      not reservation.compute_held and not reservation.disk_held and
        reservation.temporary_disk_bytes == 0 and reservation.checkpoint_bytes == 0
    end)
  end

  # @cc [owner:ghuntley,label:recovery] operation-first-terminal-evidence
  # The first applied terminal result MUST pin its immutable physical outcome.
  # Later crashes or stale/reordered observations MUST NOT replace that evidence.
  defp complete!(%{status: :completed}, _outcome), do: :ok

  defp complete!(operation, outcome) do
    operation = Ledger.update!(operation, :complete, %{completion_outcome_id: outcome.id})

    if operation.initiator == :relocation do
      [relocation] = Ledger.read!(Marshall.Compute.Relocation, id: operation.relocation_id)
      Ledger.update!(relocation, :schedule, %{})
    end

    if operation.kind == :delete do
      for relocation <-
            Ledger.read!(Marshall.Compute.Relocation,
              deletion_operation_id: operation.id,
              finished_at: [is_nil: true]
            ),
          do: Ledger.update!(relocation, :schedule, %{})
    end

    operation
  end

  # @cc [owner:ghuntley,label:recovery] activation-phase-exact-current-outcome
  # Only the current applied activation observation may classify uncertainty or
  # restore readiness checking. This changes no execution authority or capacity;
  # terminal readiness failures and successful source cleanup remain independent.
  defp record_activation_phase(%{initiator: :relocation} = operation, outcome) do
    [relocation] = Ledger.read!(Marshall.Compute.Relocation, id: operation.relocation_id)

    if relocation.activation_operation_id == operation.id do
      case {relocation.phase, outcome.state} do
        {:checking_destination, state} when state in [:failed, :unknown] ->
          if Ledger.read!(Marshall.Compute.ReadinessRequest, id: operation.id) == [],
            do: Ledger.update!(relocation, :fail_activation, %{})

        {:activation_failed, :running} ->
          Ledger.update!(relocation, :observe_activation, %{})

        _ ->
          :ok
      end
    end
  end

  defp record_activation_phase(_, _), do: :ok

  defp compatible?(kind, state) when kind in [:provision, :start, :resume],
    do: state in [:running, :failed, :unknown]

  defp compatible?(:pause, state), do: state in [:paused, :failed, :unknown]
  defp compatible?(:resize, state), do: state in [:stopped, :unknown]
  defp compatible?(:stop, state), do: state in [:stopped, :unknown]
  defp compatible?(:delete, state), do: state in [:deleted, :unknown]
end
