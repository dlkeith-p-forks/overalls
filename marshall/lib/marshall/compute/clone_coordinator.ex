defmodule Marshall.Compute.CloneCoordinator do
  @moduledoc "Durable clone queue activation and evidence-driven physical phases."
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    CloneEffect,
    CloneFailure,
    ClonePlacement,
    CloneRequest,
    Cloning,
    Host,
    Ledger,
    NetworkAddress,
    Operation,
    Reservation,
    TransferSlot,
    VirtualMachine
  }

  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:concurrency;recovery] clone-source-queue-authority
  # A source has at most one active workflow. Activation MUST select the oldest
  # unfinished queued sequence under the source advisory lock, not the job order.
  # Duplicate jobs MUST advance persisted phases, never allocate another copy.
  @spec advance(String.t()) :: {:ok, term()} | {:error, term()}
  def advance(id) do
    result =
      Ledger.transaction(fn ->
        case Ledger.read!(CloneRequest, id: id) do
          [] ->
            {:absent, []}

          [%{finished_at: finished, cleanup_completed_at: nil} = request]
          when not is_nil(finished) ->
            Cloning.lock_source!(request.source_vm_id)
            Ledger.lock!(Host, request.source_host_id)
            Ledger.lock_history!(VirtualMachine, request.source_vm_id)
            settle_cleanup!(Ledger.lock!(CloneRequest, request.id))

          [%{finished_at: finished}] when not is_nil(finished) ->
            {:finished, []}

          [request] ->
            Cloning.lock_source!(request.source_vm_id)

            case head(request.source_vm_id) do
              nil ->
                {:idle, []}

              %{id: next_id} when next_id != id ->
                {:queued, []}

              %{active: false} = next ->
                next |> ClonePlacement.reserve!() |> drive(12, [])

              next ->
                [next.source_host_id, next.destination_host_id]
                |> Enum.uniq()
                |> Enum.sort()
                |> Enum.each(&Ledger.lock!(Host, &1))

                [next.source_vm_id, next.destination_vm_id]
                |> Enum.sort()
                |> Enum.each(&Ledger.lock_history!(VirtualMachine, &1))

                drive(Ledger.lock!(CloneRequest, next.id), 12, [])
            end
        end
      end)

    case result do
      {:ok, {value, events}} ->
        unless Marshall.Repo.in_transaction?(), do: Enum.each(events, &emit_transition/1)
        {:ok, value}

      {:error, reason} when is_atom(reason) ->
        record_failure(id, reason)

      other ->
        other
    end
  end

  defp emit_transition({:clone_completed, clone_id, vm_id, destination_vm_id}),
    do:
      Marshall.Events.emit("clone.completed",
        clone_id: clone_id,
        vm_id: vm_id,
        destination_vm_id: destination_vm_id
      )

  defp emit_transition({:clone_cancelled, clone_id, vm_id}),
    do: Marshall.Events.emit("clone.cancelled", clone_id: clone_id, vm_id: vm_id)

  defp emit_transition({:clone_cleanup_deferred, clone_id, vm_id, failure}),
    do:
      Marshall.Events.emit("clone.cleanup_deferred",
        clone_id: clone_id,
        vm_id: vm_id,
        effect: CloneFailure.effect_atom(failure) || :prune,
        reason: CloneFailure.reason_atom(failure)
      )

  defp emit_transition({:clone_cleanup_completed, clone_id, vm_id}),
    do: Marshall.Events.emit("clone.cleanup_completed", clone_id: clone_id, vm_id: vm_id)

  defp emit_transition({:clone_activation_deferred, clone_id, vm_id, reason}),
    do:
      Marshall.Events.emit("clone.activation_deferred",
        clone_id: clone_id,
        vm_id: vm_id,
        reason: reason
      )

  defp emit_transition({:clone_phase_failed, clone_id, vm_id, phase, failure}),
    do:
      Marshall.Events.emit("clone.phase_failed",
        clone_id: clone_id,
        vm_id: vm_id,
        phase: phase,
        reason: CloneFailure.reason_atom(failure)
      )

  defp emit_transition({:clone_failed, clone_id, vm_id, failure}),
    do:
      Marshall.Events.emit("clone.failed",
        clone_id: clone_id,
        vm_id: vm_id,
        reason: CloneFailure.reason_atom(failure),
        effect: CloneFailure.effect_atom(failure)
      )

  # Advance purely durable boundaries immediately. Stop on missing physical
  # evidence; the bounded loop cannot turn host work into an in-transaction wait.
  defp drive(request, 0, events), do: {request, events}

  defp drive(request, remaining, events) do
    case step(request) do
      {%CloneRequest{} = next, event} ->
        fields = [:phase, :source_operation_id, :source_restored_at]
        events = if is_list(event), do: Enum.reverse(event) ++ events, else: [event | events]

        if next.active and Map.take(next, fields) != Map.take(request, fields),
          do: drive(next, remaining - 1, events),
          else: {next, events}

      %CloneRequest{} = next ->
        fields = [:phase, :source_operation_id, :source_restored_at]

        if next.active and Map.take(next, fields) != Map.take(request, fields),
          do: drive(next, remaining - 1, events),
          else: {next, events}

      result ->
        {result, events}
    end
  end

  defp head(source) do
    CloneRequest
    |> Ash.Query.filter(source_vm_id == ^source and is_nil(finished_at))
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: SystemActor.compute())
  end

  # @cc [owner:ghuntley,label:recovery] clone-refusals-are-durable
  # A queued head refused by a transient host condition (busy transfer slot,
  # a previous copy's retained snapshot) MUST wait in the queue with the
  # reason recorded, not fail; it is re-scheduled when the condition clears.
  # Any other queued refusal fails durably with its real reason, and a
  # refusal in an active phase is recorded on the request so the owner sees
  # it, instead of being dropped with the transaction.
  @transient [:transfer_busy, :source_cleanup_pending]

  defp record_failure(id, reason) do
    result =
      Ledger.transaction(fn ->
        [original] = Ledger.read!(CloneRequest, id: id)
        Cloning.lock_source!(original.source_vm_id)
        request = Ledger.lock!(CloneRequest, original.id)
        failure = Atom.to_string(reason)

        cond do
          request.finished_at != nil ->
            {:error, reason}

          request.phase == :queued and not request.active and
            match?(%{id: ^id}, head(original.source_vm_id)) and reason in @transient ->
            changed = request.deferred_reason != failure

            request =
              Ledger.update!(request, :defer, %{
                deferred_reason: failure,
                deferred_at: Ledger.now()
              })

            {request,
             if(changed,
               do: [{:clone_activation_deferred, request.id, request.source_vm_id, reason}],
               else: []
             )}

          request.phase == :queued and not request.active and
              match?(%{id: ^id}, head(original.source_vm_id)) ->
            request =
              Ledger.update!(request, :fail, %{
                failure: failure,
                finished_at: Ledger.now(),
                cleanup_completed_at: Ledger.now()
              })

            schedule_next!(request.source_vm_id)
            {request, [{:clone_failed, request.id, request.source_vm_id, request.failure}]}

          request.active and request.failure == nil ->
            request = Ledger.update!(request, :record_progress, %{failure: failure})

            {request,
             [{:clone_phase_failed, request.id, request.source_vm_id, request.phase, failure}]}

          true ->
            {:error, reason}
        end
      end)

    case result do
      {:ok, {%CloneRequest{} = request, events}} ->
        unless Marshall.Repo.in_transaction?(), do: Enum.each(events, &emit_transition/1)
        {:ok, request}

      other ->
        other
    end
  end

  # @cc [owner:ghuntley,label:performance] clone-queue-advances-immediately
  # Finishing, failing or settling a request MUST schedule the next queued
  # request of the same source at once instead of waiting for the per-minute
  # scheduler; slot release MUST wake requests deferred for a busy slot.
  defp schedule_next!(source_vm_id) do
    case head(source_vm_id) do
      %{active: false, finished_at: nil} = next -> Ledger.update!(next, :schedule, %{})
      _ -> :ok
    end

    :ok
  end

  defp schedule_deferred!(reason) do
    CloneRequest
    |> Ash.Query.filter(
      phase == :queued and active == false and is_nil(finished_at) and
        deferred_reason == ^Atom.to_string(reason)
    )
    |> Ash.Query.limit(16)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.each(&Ledger.update!(&1, :schedule, %{}))
  end

  defp step(%{phase: :cancelling} = request),
    do: cancel(request)

  defp step(%{phase: :preparing} = request) do
    ready =
      effect(request, :prepare, :destination) && effect(request, :probe, :source) &&
        effect(request, :connect, :destination)

    case ready do
      nil ->
        :preparing

      _ ->
        [source] = Ledger.read!(VirtualMachine, id: request.source_vm_id)

        if request.original_power_state == :running do
          operation = operation!(source, request, :stop)

          Ledger.update!(request, :stop_source, %{source_operation_id: operation.id})
        else
          Ledger.update!(request, :capture, %{})
        end
    end
  end

  # @cc [owner:ghuntley,label:recovery] clone-stop-failure-recorded
  # A source stop that completes in another state, or is cancelled by another
  # lifecycle request, MUST be recorded as source_stop_failed instead of
  # waiting forever; an owner retry issues one new stop only while the source
  # generation is unchanged, and cancellation returns lifecycle to the owner.
  defp step(%{phase: :stopping} = request) do
    cond do
      completed?(request.source_operation_id, :stopped) ->
        Ledger.update!(request, :capture, %{})

      request.failure == "retry_source_stop" ->
        [source] = Ledger.read!(VirtualMachine, id: request.source_vm_id)
        [previous] = Ledger.read!(Operation, id: request.source_operation_id)

        if source.generation == previous.generation do
          operation = operation!(source, request, :stop)

          Ledger.update!(request, :record_progress, %{
            source_operation_id: operation.id,
            failure: nil
          })
        else
          :stopping
        end

      request.failure == nil and stop_failed?(request.source_operation_id) ->
        Ledger.update!(request, :record_progress, %{failure: "source_stop_failed"})

      true ->
        :stopping
    end
  end

  defp step(%{phase: :capturing} = request) do
    case effect(request, :capture, :source) do
      nil ->
        :capturing

      snapshot ->
        request = Ledger.update!(request, :confirm_capture, %{snapshot: snapshot})

        if request.original_power_state == :running do
          [source] = Ledger.read!(VirtualMachine, id: request.source_vm_id)
          operation = operation!(source, request, :start)
          Ledger.update!(request, :record_progress, %{source_operation_id: operation.id})
        else
          Ledger.update!(request, :record_progress, %{source_restored_at: Ledger.now()})
        end
    end
  end

  defp step(%{phase: :copying} = request) do
    request = restore(request)

    if effect(request, :copy, :destination),
      do: Ledger.update!(request, :confirm_copy, %{}),
      else: :copying
  end

  defp step(%{phase: :publishing} = request) do
    request = restore(request)

    if effect(request, :adopt, :destination) do
      [destination] = Ledger.read!(VirtualMachine, id: request.destination_vm_id)
      Marshall.Ingress.Endpoints.ensure!(destination)
      now = Ledger.now()

      attrs = %{
        published_at: now,
        cleanup_deadline_at: DateTime.add(now, cleanup_deadline_ms(), :millisecond)
      }

      # Even a stopped copy receives a real retained execution command/outcome,
      # so Lilly tracks its ownership and capacity coverage without booting it.
      kind = if request.original_power_state == :running, do: :start, else: :stop
      operation = operation!(destination, request, kind)
      attrs = Map.put(attrs, :destination_operation_id, operation.id)

      Ledger.update!(request, :publish, attrs)
    else
      :publishing
    end
  end

  # @cc [owner:ghuntley,label:recovery;capacity] clone-cleanup-deadline-retains-hold
  # A published, restored, settled and quiescent request whose source prune is
  # still unconfirmed at its cleanup deadline completes so the copy is an
  # ordinary machine, but the source temporary disk hold, the source's
  # exclusion and the prune offer are retained until the prune receipt lands.
  # The deadline never releases physical resources on its own.
  defp step(%{phase: :cleaning} = request) do
    request = request |> restore() |> release_quiescent_slots!()

    # Publication hands lifecycle authority back to the ordinary VM model. A
    # later stop/delete settles the original start without issuing another start.
    cond do
      request.source_restored_at && quiescent?(request) && effect(request, :prune, :source) ->
        case destination_settled(request) do
          nil -> :cleaning
          phase -> finish!(request, phase)
        end

      request.source_restored_at && quiescent?(request) &&
        destination_settled(request) == :complete && deadline_passed?(request) ->
        finish!(request, :complete, cleanup_pending: true)

      true ->
        :cleaning
    end
  end

  defp step(request), do: request.phase

  defp deadline_passed?(%{cleanup_deadline_at: nil}), do: false

  defp deadline_passed?(%{cleanup_deadline_at: deadline}),
    do: DateTime.compare(Ledger.now(), deadline) != :lt

  defp cleanup_deadline_ms,
    do: Application.get_env(:marshall, :clone_cleanup_deadline_ms, 300_000)

  # @cc [owner:ghuntley,label:concurrency;recovery] clone-stream-slots-require-both-revocations
  # A clone's transfer slots release only once both endpoint revoke receipts
  # are on record (the stream can neither start nor resume), exactly as a
  # relocation's slots do. Source restoration, pruning and destination
  # settlement may remain pending; they never need the slot. Replays keep the
  # first release timestamps, and a release wakes requests deferred for a
  # busy slot.
  defp release_quiescent_slots!(request) do
    if quiescent?(request) do
      slots =
        Ledger.read!(TransferSlot, clone_request_id: request.id, released_at: [is_nil: true])

      for slot <- slots, do: Ledger.update!(slot, :release, %{released_at: Ledger.now()})
      if slots != [], do: schedule_deferred!(:transfer_busy)
    end

    request
  end

  defp settle_cleanup!(request) do
    if effect(request, :prune, :source) do
      [hold] =
        Ledger.read!(Reservation, placement_id: request.specification["source"]["placement_id"])

      Ledger.update!(hold, :release_temporary_disk, %{})
      request = Ledger.update!(request, :complete_cleanup, %{cleanup_completed_at: Ledger.now()})
      schedule_next!(request.source_vm_id)
      schedule_deferred!(:source_cleanup_pending)
      {request, [{:clone_cleanup_completed, request.id, request.source_vm_id}]}
    else
      {:cleanup_pending, []}
    end
  end

  defp destination_settled(request) do
    [operation] = Ledger.read!(Operation, id: request.destination_operation_id)
    [vm] = Ledger.history!(VirtualMachine, id: request.destination_vm_id)

    cond do
      vm.generation > operation.generation -> :complete
      completed?(operation.id, request.original_power_state) -> :complete
      completed?(operation.id, :failed) -> :failed
      true -> nil
    end
  end

  defp restore(%{source_restored_at: at} = request) when not is_nil(at), do: request

  defp restore(request) do
    cond do
      request.failure == "retry_source_restart" and
          completed?(request.source_operation_id, :failed) ->
        [source] = Ledger.read!(VirtualMachine, id: request.source_vm_id)
        [previous] = Ledger.read!(Operation, id: request.source_operation_id)

        if source.generation == previous.generation do
          operation = operation!(source, request, :start)

          Ledger.update!(request, :record_progress, %{
            source_operation_id: operation.id,
            failure: nil
          })
        else
          request
        end

      completed?(request.source_operation_id, :running) ->
        Ledger.update!(request, :record_progress, %{
          source_restored_at: Ledger.now(),
          failure: nil
        })

      completed?(request.source_operation_id, :failed) ->
        Ledger.update!(request, :record_progress, %{failure: "source_restart_failed"})

      true ->
        request
    end
  end

  defp cancel(request) do
    request = request |> restore_cancelled() |> release_quiescent_slots!()

    if quiescent?(request) && effect(request, :discard, :destination) &&
         effect(request, :prune, :source) && request.source_restored_at do
      [destination] = Ledger.read!(VirtualMachine, id: request.destination_vm_id)

      for hold <- Ledger.read!(Reservation, vm_id: destination.id),
          do: Ledger.update!(hold, :release_all, %{})

      for address <- Ledger.read!(NetworkAddress, vm_id: destination.id),
          do: Ledger.archive!(address, :release)

      Ledger.archive!(destination, :archive)
      finish!(request, :cancelled)
    else
      :cancelling
    end
  end

  defp restore_cancelled(%{source_restored_at: at} = request) when not is_nil(at), do: request

  defp restore_cancelled(%{source_operation_id: nil} = request),
    do: Ledger.update!(request, :record_progress, %{source_restored_at: Ledger.now()})

  defp restore_cancelled(request) do
    cond do
      request.original_power_state == :stopped ->
        Ledger.update!(request, :record_progress, %{source_restored_at: Ledger.now()})

      # A stop that never took effect leaves the source under its ordinary
      # lifecycle; cancellation owes it no restart.
      request.failure in ["source_stop_failed", "retry_source_stop"] or
          stop_failed?(request.source_operation_id) ->
        Ledger.update!(request, :record_progress, %{
          source_restored_at: Ledger.now(),
          failure: nil
        })

      completed?(request.source_operation_id, :stopped) ->
        [source] = Ledger.read!(VirtualMachine, id: request.source_vm_id)
        operation = operation!(source, request, :start)
        Ledger.update!(request, :record_progress, %{source_operation_id: operation.id})

      true ->
        restore(request)
    end
  end

  defp quiescent?(request) do
    results = for endpoint <- [:source, :destination], do: effect(request, :revoke, endpoint)
    Enum.all?(results, &is_map/1)
  end

  defp finish!(request, phase, options \\ []) do
    cleanup_pending = Keyword.get(options, :cleanup_pending, false)
    now = Ledger.now()

    unless cleanup_pending do
      [hold] =
        Ledger.read!(Reservation, placement_id: request.specification["source"]["placement_id"])

      Ledger.update!(hold, :release_temporary_disk, %{})
    end

    for slot <-
          Ledger.read!(TransferSlot, clone_request_id: request.id, released_at: [is_nil: true]),
        do: Ledger.update!(slot, :release, %{released_at: now})

    retained = request.failure

    request =
      Ledger.update!(request, phase_action(phase), %{
        active: false,
        finished_at: now,
        failure: if(phase == :failed, do: "destination_start_failed", else: nil),
        name_released_at: now,
        cleanup_completed_at: if(cleanup_pending, do: nil, else: now)
      })

    schedule_next!(request.source_vm_id)

    events =
      if cleanup_pending,
        do: [
          {:clone_cleanup_deferred, request.id, request.source_vm_id, retained},
          transition(request, phase)
        ],
        else: [transition(request, phase)]

    {request, events}
  end

  defp phase_action(:complete), do: :complete
  defp phase_action(:cancelled), do: :cancel
  defp phase_action(:failed), do: :fail

  defp transition(request, :complete),
    do: {:clone_completed, request.id, request.source_vm_id, request.destination_vm_id}

  defp transition(request, :cancelled),
    do: {:clone_cancelled, request.id, request.source_vm_id}

  defp transition(request, :failed),
    do: {:clone_failed, request.id, request.source_vm_id, request.failure}

  defp stop_failed?(nil), do: false

  defp stop_failed?(id) do
    case Ledger.read!(Operation, id: id) do
      [%{status: :cancelled}] -> true
      _ -> completed?(id, :failed)
    end
  end

  defp completed?(nil, _state), do: false

  defp completed?(id, state) do
    with [%{status: :completed, completion_outcome_id: outcome}] <-
           Ledger.read!(Operation, id: id),
         [receipt] <- Ledger.read!(Marshall.Compute.PhysicalOutcome, id: outcome),
         do: receipt.observation["state"] == Atom.to_string(state),
         else: (_ -> false)
  end

  defp operation!(vm, request, kind) do
    vm =
      Ledger.intent!(vm, %{
        generation: vm.generation + 1,
        desired_state: if(kind == :start, do: :running, else: :stopped),
        crash_restart_times: []
      })

    Ledger.create!(Operation, :enqueue, %{
      vm_id: vm.id,
      placement_id: vm.current_placement_id,
      execution_epoch: vm.execution_epoch,
      generation: vm.generation,
      kind: kind,
      initiator: :clone,
      clone_request_id: request.id
    })
  end

  defp effect(request, kind, endpoint) do
    host = request.specification[Atom.to_string(endpoint)]["host_id"]

    case Ledger.read!(CloneEffect,
           clone_request_id: request.id,
           host_id: host,
           kind: kind,
           endpoint: endpoint
         ) do
      [%{result: result}] ->
        result

      [] ->
        [source] = Ledger.read!(VirtualMachine, id: request.source_vm_id)

        payload = %{
          "specification" => request.specification,
          "snapshot" => request.snapshot,
          "source_generation" => source.generation,
          "endpoint" => Atom.to_string(endpoint)
        }

        Ledger.create!(CloneEffect, :record, %{
          clone_request_id: request.id,
          host_id: host,
          kind: kind,
          endpoint: endpoint,
          payload: payload
        })

        nil
    end
  end
end
