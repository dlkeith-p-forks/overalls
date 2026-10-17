defmodule Marshall.Compute.Resize do
  @moduledoc "Host-serialized stop, physical resize and optional restart."
  use Ash.Resource.Actions.Implementation

  alias Marshall.Compute.{
    Budget,
    CommandSnapshot,
    Host,
    Ledger,
    Lifecycle,
    NetworkAddress,
    Operation,
    Reservation,
    ResizeRequest,
    RestartCapacity,
    StoragePool,
    VirtualMachine
  }

  alias Marshall.Authorization.SystemActor
  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;concurrency] resize-authority-after-lock
  # Resize and retry MUST recheck manage access under host-before-VM locks, reject
  # stale generation or changed placement, and commit intent and capacity together.
  # Exact original retries MUST return their record without repeating effects.
  @impl true
  def run(input, options, context) do
    args = input.arguments

    result =
      Ledger.transaction(
        fn ->
          Ecto.Adapters.SQL.query!(
            Marshall.Repo,
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            ["resize:#{context.actor.id}:#{args.vm_id}"],
            log: false
          )

          vm = vm!(args.vm_id)
          Marshall.Access.Authorization.require!(vm, context.actor, "manage")

          host = Ledger.lock!(Host, vm.host_id)
          authority = {vm.current_placement_id, vm.execution_epoch}
          vm = vm!(vm.id, true)
          Marshall.Access.Authorization.require!(vm, context.actor, "manage")

          unless vm.host_id == host.id and
                   {vm.current_placement_id, vm.execution_epoch} == authority,
                 do: Ledger.rollback(:placement_changed)

          cond do
            Keyword.get(options, :retry, false) -> retry!(host, vm, args, context.actor)
            Keyword.get(options, :cancel, false) -> cancel!(vm, args)
            true -> request!(host, vm, args, context.actor)
          end
        end,
        context.actor
      )

    case result do
      {:ok, {request, pending}} ->
        unless Marshall.Repo.in_transaction?() do
          Enum.each(pending, fn
            {:resize_requested, vm_id, operation_id} ->
              Marshall.Events.emit("vm.resize_requested",
                vm_id: vm_id,
                operation_id: operation_id
              )

            {:resize_phase, vm_id, phase} ->
              Marshall.Events.emit("vm.resize_phase", vm_id: vm_id, operation_status: phase)

            {:resize_cancelled, vm_id, request_id} ->
              Marshall.Events.emit("vm.resize_cancelled",
                vm_id: vm_id,
                resize_request_id: request_id
              )
          end)
        end

        {:ok, request}

      {:error, reason} when is_atom(reason) ->
        # Every refusal is a closed coordinator reason; name it where the
        # operator looks instead of leaving only a generic page flash. Inside an
        # enclosing transaction (a Porsche request) the rollback propagates to
        # that transaction, whose gateway logs the refusal itself.
        unless Marshall.Repo.in_transaction?(),
          do: Marshall.Events.emit("vm.resize_refused", vm_id: args.vm_id, reason: reason)

        {:error, Marshall.Compute.Error.exception(reason: reason)}

      result ->
        result
    end
  end

  @spec busy?(String.t()) :: boolean()
  def busy?(vm_id), do: active(vm_id) != nil

  @spec host_busy?(String.t()) :: boolean()
  def host_busy?(host_id) do
    ResizeRequest
    |> Ash.Query.filter(host_id == ^host_id and is_nil(finished_at))
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: SystemActor.compute()) != []
  end

  @spec active(String.t()) :: ResizeRequest.t() | nil
  def active(vm_id) do
    ResizeRequest
    |> Ash.Query.filter(vm_id == ^vm_id and is_nil(finished_at))
    |> Ash.read_one!(actor: SystemActor.compute())
  end

  defp request!(host, vm, args, actor) do
    target = OverallsProtocol.Resize.sizes(args)

    case Ledger.read!(ResizeRequest,
           vm_id: vm.id,
           requested_by_id: actor.id,
           request_key: args.idempotency_key
         ) do
      [request] ->
        unless request.target_sizes == target and
                 request.expected_generation == args.expected_generation,
               do: Ledger.rollback(:idempotency_conflict)

        {request, []}

      [] ->
        validate_generation!(vm, args.expected_generation)
        if Marshall.Compute.RelocationGuard.vm_busy?(vm.id), do: Ledger.rollback(:vm_busy)

        unless vm.desired_state in [:running, :stopped] and vm.observed_state == vm.desired_state and
                 Enum.all?(
                   Ledger.read!(Operation, vm_id: vm.id),
                   &(&1.status in [:completed, :cancelled])
                 ),
               do: Ledger.rollback(:vm_busy)

        source = OverallsProtocol.Resize.sizes(vm)

        unless OverallsProtocol.Resize.valid_transition?(source, args) and source != target,
          do: Ledger.rollback(:invalid_vm_size)

        unless Marshall.Compute.Profiles.size_valid?(vm.profile, target),
          do: Ledger.rollback(:image_requirements_not_met)

        [reservation] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
        reserve!(host, vm, reservation, target, vm.desired_state == :running)

        request =
          Ledger.create!(ResizeRequest, :record, %{
            vm_id: vm.id,
            host_id: host.id,
            requested_by_id: actor.id,
            request_key: args.idempotency_key,
            expected_generation: args.expected_generation,
            original_sizes: source,
            target_sizes: target,
            original_power_state: vm.desired_state
          })

        request = enqueue!(vm, request, :stopping)
        {request, [{:resize_requested, vm.id, request.operation_id}]}
    end
  end

  defp retry!(host, vm, args, actor) do
    validate_generation!(vm, args.expected_generation)
    request = active(vm.id)

    unless request != nil and request.id == args.request_id and request.failure != nil,
      do: Ledger.rollback(:resize_not_retryable)

    [reservation] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
    restart = request.original_power_state == :running
    reserve!(host, vm, reservation, request.target_sizes, restart)
    phase = if request.phase == :fencing, do: :restarting, else: request.phase

    if phase == :restarting and vm.observed_state != :stopped,
      do: Ledger.rollback(:stop_unconfirmed)

    request = enqueue!(vm, request, phase, actor.id)
    {request, [{:resize_phase, vm.id, phase}]}
  end

  # @cc [owner:ghuntley,label:recovery;product] resize-cancel-before-mutation
  # A resize MAY be cancelled only while no size has been applied: in the stop
  # phase, or already cancelling. Cancellation restores the original holds at
  # once, then follows the stop evidence: a confirmed stop restarts an
  # originally running machine through an ordinary start and finishes as
  # cancelled when it runs; an originally stopped machine finishes as
  # cancelled at once. A pending stop is awaited in the cancelling phase. A
  # request fenced by unconfirmed physical state, or past the stop phase, is
  # refused resize_not_cancellable and keeps retry as its only path.
  defp cancel!(vm, args) do
    request = active(vm.id)

    unless request != nil and request.id == args.request_id and
             request.phase in [:stopping, :cancelling],
           do: Ledger.rollback(:resize_not_cancellable)

    if request.phase == :cancelling do
      {request, []}
    else
      [operation] = Ledger.read!(Operation, id: request.operation_id)
      stopped = operation.status == :completed and vm.observed_state == :stopped
      pending = operation.status not in [:completed, :cancelled] and request.failure == nil
      unless stopped or pending, do: Ledger.rollback(:resize_not_cancellable)

      [reservation] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
      restart = request.original_power_state == :running
      original = OverallsProtocol.VMShape.reservation(with_sizes(vm, request.original_sizes))

      Ledger.update!(reservation, :resize_hold, %{
        vcpu: original.vcpu,
        memory_bytes: original.memory_bytes,
        pending_disk_bytes: 0,
        compute_held: restart,
        startup_compute_held: restart
      })

      request =
        Ledger.update!(request, :cancel, %{
          operation_id: request.operation_id,
          failure: nil,
          cancelled_at: Ledger.now()
        })

      cond do
        pending ->
          {request, [{:resize_phase, vm.id, :cancelling}]}

        restart ->
          request = enqueue!(vm, request, :restarting)
          {request, [{:resize_phase, vm.id, :restarting}]}

        true ->
          request = cancelled!(request, reservation)
          {request, [{:resize_cancelled, vm.id, request.id}]}
      end
    end
  end

  defp cancelled!(request, reservation) do
    if reservation, do: Ledger.update!(reservation, :release_compute, %{})
    Ledger.update!(request, :cancelled, %{finished_at: Ledger.now(), failure: nil})
  end

  defp validate_generation!(vm, generation) do
    if vm.archived_at != nil or vm.desired_state == :deleted, do: Ledger.rollback(:vm_deleted)
    if vm.generation != generation, do: Ledger.rollback(:stale_generation)
  end

  defp reserve!(host, vm, reservation, target, restart) do
    unless host.enabled and host.maintenance_mode == :normal and
             host.inventory["execution_ready"] == true and
             Marshall.Compute.HostLiveness.capacity_fresh?(host.reported_at, Ledger.now()) and
             reservation.disk_held,
           do: Ledger.rollback(:host_unavailable)

    [pool] = Ledger.read!(StoragePool, id: vm.pool_id)

    unless Marshall.Compute.HostLiveness.capacity_fresh?(pool.reported_at, Ledger.now()),
      do: Ledger.rollback(:host_unavailable)

    shape = with_sizes(vm, target)

    if restart and not RestartCapacity.fits?(host, shape, reservation),
      do: Ledger.rollback(:insufficient_capacity)

    growth = target["disk_bytes"] - vm.disk_bytes

    reservations =
      Ledger.read!(Reservation, host_id: host.id)
      |> Enum.map(fn r ->
        if r.id == reservation.id, do: %{r | pending_disk_bytes: 0}, else: r
      end)

    unless Budget.physical_disk_available(host, pool, reservations) >= growth,
      do: Ledger.rollback(:insufficient_capacity)

    needed = OverallsProtocol.VMShape.reservation(shape)

    Ledger.update!(reservation, :resize_hold, %{
      vcpu: needed.vcpu,
      memory_bytes: needed.memory_bytes,
      pending_disk_bytes: growth,
      compute_held: restart,
      startup_compute_held: restart
    })
  end

  # @cc [owner:ghuntley,label:recovery] resize-evidence-advances-phase
  # Only current operation evidence may advance resize. Confirmed stop MUST precede
  # disk mutation; only exact target-size proof commits sizes. Restart failure MUST
  # fence and stop before offering restart retry. Unknown state retains all holds.
  @spec outcome_locked!(VirtualMachine.t(), Operation.t(), OverallsProtocol.Execution.outcome()) ::
          {:ok, [Marshall.Compute.Outcomes.transition()]} | :ordinary
  def outcome_locked!(vm, operation, outcome) do
    [request] = Ledger.read!(ResizeRequest, id: operation.resize_request_id)

    if request.finished_at do
      :ordinary
    else
      unless request.operation_id == operation.id, do: Ledger.rollback(:invalid_outcome)

      vm =
        Ledger.update!(vm, :observe, %{
          observed_state: outcome.state,
          observed_at: Ledger.now(),
          outcome_sequence: outcome.sequence,
          failure_reason: if(outcome.reason == :none, do: nil, else: outcome.reason)
        })

      :ok
      [reservation] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)

      transitions =
        case {request.phase, outcome.state} do
          {:stopping, :stopped} when outcome.disk_present ->
            complete!(operation, outcome)
            enqueue!(vm, request, :resizing)
            [{:resize_phase, vm.id, :resizing}]

          # A stop that confirms the guest down but cannot vouch for its disk is
          # host evidence to record, not a protocol violation that aborts the
          # whole exchange: the request keeps its holds and waits for a retry.
          {:stopping, :stopped} ->
            Ledger.update!(request, :record_progress, %{failure: "physical_state_unconfirmed"})
            [{:resize_failed, vm.id, failure_reason("physical_state_unconfirmed")}]

          {:cancelling, :stopped} ->
            complete!(operation, outcome)

            if request.original_power_state == :running do
              enqueue!(vm, request, :restarting)
              [{:resize_phase, vm.id, :restarting}]
            else
              request = cancelled!(request, reservation)
              [{:resize_cancelled, vm.id, request.id}]
            end

          {:resizing, :stopped} ->
            unless Map.get(outcome, :applied_sizes) == request.target_sizes and
                     outcome.disk_present,
                   do: Ledger.rollback(:invalid_outcome)

            complete!(operation, outcome)
            vm = Ledger.update!(vm, :apply_resize, atom_sizes(request.target_sizes))

            Ledger.update!(reservation, :resize_hold, %{
              disk_bytes: OverallsProtocol.VMShape.reservation(vm).disk_bytes,
              pending_disk_bytes: 0
            })

            if request.original_power_state == :running do
              [host] = Ledger.read!(Host, id: vm.host_id)
              restart_decision!(host, vm, request, reservation)
            else
              request = finish!(request, reservation)
              [{:resize_finished, vm.id, request.operation_id}]
            end

          {:restarting, :running} when not is_nil(request.cancelled_at) ->
            complete!(operation, outcome)
            request = cancelled!(request, nil)
            [{:resize_cancelled, vm.id, request.id}]

          {:restarting, :running} ->
            complete!(operation, outcome)

            request =
              Ledger.update!(request, :complete, %{
                finished_at: Ledger.now(),
                failure: nil
              })

            [{:resize_finished, vm.id, request.operation_id}]

          {:restarting, state} when state in [:failed, :unknown] ->
            complete!(operation, outcome)
            enqueue!(vm, request, :fencing)
            [{:resize_phase, vm.id, :fencing}]

          {:fencing, :stopped} ->
            complete!(operation, outcome)
            Ledger.update!(reservation, :release_compute, %{})
            Ledger.update!(request, :record_progress, %{failure: "restart_failed"})
            [{:resize_failed, vm.id, failure_reason("restart_failed")}]

          {_, :unknown} ->
            Ledger.update!(request, :record_progress, %{failure: "physical_state_unconfirmed"})
            [{:resize_failed, vm.id, failure_reason("physical_state_unconfirmed")}]

          _ ->
            Ledger.rollback(:invalid_outcome)
        end

      {:ok, transitions}
    end
  end

  defp failure_reason(failure) do
    case failure do
      "insufficient_capacity" -> :insufficient_capacity
      "restart_failed" -> :restart_failed
      "physical_state_unconfirmed" -> :physical_state_unconfirmed
      "workspace_source_unavailable" -> :workspace_source_unavailable
    end
  end

  # @cc [owner:ghuntley,label:capacity;recovery] resize-restart-waits-for-fresh-capacity
  # After the disk resize is confirmed, a running VM restarts only when fresh
  # telemetry shows it fits. A measured shortfall fails the resize (releasing
  # compute, keeping the disk); telemetry that is merely too old MUST NOT fail
  # it: the request keeps every hold in :resizing with its completed operation
  # and resume_awaiting_locked!/1 re-decides on the host's next accepted report.
  # Unavailable source capability MUST commit confirmed resized sizes/outcomes,
  # refuse only the restart and release confirmed compute while retaining disk.
  defp restart_decision!(host, vm, request, reservation) do
    decision =
      if CommandSnapshot.workspace_source_available?(vm),
        do: RestartCapacity.check(host, vm, reservation),
        else: :source_unavailable

    case decision do
      :fits ->
        enqueue!(vm, request, :restarting)
        [{:resize_phase, vm.id, :restarting}]

      :stale ->
        []

      :insufficient ->
        Ledger.update!(reservation, :release_compute, %{})
        Ledger.update!(request, :restart, %{failure: "insufficient_capacity"})
        [{:resize_failed, vm.id, failure_reason("insufficient_capacity")}]

      :source_unavailable ->
        Ledger.update!(reservation, :release_compute, %{})

        Ledger.update!(request, :complete, %{
          finished_at: Ledger.now(),
          failure: "workspace_source_unavailable"
        })

        [{:resize_failed, vm.id, failure_reason("workspace_source_unavailable")}]
    end
  end

  @doc """
  Trusted coordinator only: caller holds the host row lock in a ledger
  transaction and has just accepted a fresh report. Resumes this host's
  resizes whose disk change is confirmed but whose restart awaited fresh
  capacity telemetry.
  """
  @spec resume_awaiting_locked!(Host.t()) :: [Marshall.Compute.Outcomes.transition()]
  def resume_awaiting_locked!(host) do
    Ledger.read!(ResizeRequest,
      host_id: host.id,
      phase: :resizing,
      finished_at: [is_nil: true],
      failure: [is_nil: true],
      original_power_state: :running
    )
    |> Enum.flat_map(fn request ->
      with [%{status: :completed}] <- Ledger.read!(Operation, id: request.operation_id),
           vm = Ledger.lock!(VirtualMachine, request.vm_id),
           true <- vm.host_id == host.id and vm.archived_at == nil,
           [reservation] <- Ledger.read!(Reservation, placement_id: vm.current_placement_id) do
        restart_decision!(host, vm, request, reservation)
      else
        _ -> []
      end
    end)
  end

  defp finish!(request, reservation) do
    Ledger.update!(reservation, :release_compute, %{})

    Ledger.update!(request, :complete, %{finished_at: Ledger.now(), failure: nil})
  end

  defp complete!(%{status: :completed}, _), do: :ok

  defp complete!(operation, outcome),
    do: Ledger.update!(operation, :complete, %{completion_outcome_id: outcome.id})

  # @cc [owner:ghuntley,label:product] resize-retry-requester-provenance
  # Retry operations MUST identify the actor who authorized that retry. Subsequent
  # automatic phases inherit that operation's requester without rewriting the
  # original resize requester or any prior operation.
  defp enqueue!(vm, request, phase, requester_id \\ nil) do
    requester_id = requester_id || phase_requester(request)

    kind =
      case phase do
        :stopping -> :stop
        :resizing -> :resize
        :restarting -> :start
        :fencing -> :stop
        :cancelling -> :stop
      end

    Lifecycle.cancel_operations!(vm.id)

    vm =
      Ledger.intent!(vm, %{
        generation: Lifecycle.next_generation!(vm),
        desired_state: if(kind == :start, do: :running, else: :stopped),
        crash_restart_times: []
      })

    [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)
    id = Ash.UUID.generate()
    shape = if kind == :resize, do: with_sizes(vm, request.target_sizes), else: vm

    command = %{
      id: id,
      owner_id: vm.owner_id,
      vm_id: vm.id,
      placement_id: vm.current_placement_id,
      execution_epoch: vm.execution_epoch,
      host_id: vm.host_id,
      pool_id: vm.pool_id,
      generation: vm.generation,
      kind: kind,
      architecture: vm.architecture,
      profile: vm.profile,
      vcpu: shape.vcpu,
      memory_bytes: shape.memory_bytes,
      disk_bytes: shape.disk_bytes,
      image_id: vm.image_id,
      slot: address.slot
    }

    command =
      if kind == :resize,
        do: Map.merge(command, %{resize_from: request.original_sizes, resize_id: request.id}),
        else: command

    command = if kind == :start, do: Map.put(command, :resize_id, request.id), else: command

    operation =
      Ledger.create!(Operation, :enqueue, %{
        id: id,
        vm_id: vm.id,
        placement_id: vm.current_placement_id,
        execution_epoch: vm.execution_epoch,
        generation: vm.generation,
        kind: kind,
        requested_by_id: requester_id,
        resize_request_id: request.id,
        command_snapshot: OverallsProtocol.Execution.encode_command(command)
      })

    Ledger.update!(request, phase_action(phase), %{operation_id: operation.id, failure: nil})
  end

  defp phase_action(:stopping), do: :stop
  defp phase_action(:resizing), do: :resize
  defp phase_action(:restarting), do: :restart
  defp phase_action(:fencing), do: :fence
  defp phase_action(:cancelling), do: :cancel

  defp phase_requester(%{operation_id: nil} = request), do: request.requested_by_id

  defp phase_requester(request) do
    case Ledger.read!(Operation,
           id: request.operation_id,
           vm_id: request.vm_id,
           resize_request_id: request.id
         ) do
      [operation] -> operation.requested_by_id
      _ -> Ledger.rollback(:invalid_resize_operation)
    end
  end

  defp atom_sizes(sizes),
    do: Map.new([:vcpu, :memory_bytes, :disk_bytes], &{&1, Map.fetch!(sizes, Atom.to_string(&1))})

  defp with_sizes(vm, sizes), do: struct(vm, atom_sizes(sizes))

  defp vm!(id, lock \\ false) do
    query =
      VirtualMachine
      |> Ash.Query.for_read(:history, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(id == ^id)

    query = if lock, do: Ash.Query.lock(query, :for_update), else: query
    Ash.read_one!(query, actor: SystemActor.compute()) || Ledger.rollback(:forbidden)
  end
end
