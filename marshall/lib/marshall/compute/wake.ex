defmodule Marshall.Compute.Wake do
  @moduledoc "Authorized wake demand, fresh local admission and automatic paused-copy placement."
  alias Marshall.Compute.{
    Host,
    Ledger,
    Lifecycle,
    Operation,
    Relocation,
    Reservation,
    VirtualMachine,
    WakeRequest,
    WakeRequestKey
  }

  require Marshall.Events

  @type source :: :user | :prompt | :network | :pin
  @type request_result :: WakeRequest.t() | :already_running
  @type status :: {:ready, VirtualMachine.t()} | {:pending, WakeRequest.t()} | {:error, atom()}

  # @cc [owner:ghuntley,label:security;concurrency] wake-admission-current-authority
  # Public demand MUST recheck the current VM permission under its VM lock.
  # Capacity is acquired later under host-before-VM locks; admission MUST NOT
  # acquire a host lock from this VM-locked transaction or execute a guest.
  @spec request(String.t(), source(), Marshall.Accounts.User.t(), String.t() | nil) ::
          {:ok, request_result()} | {:error, term()}
  def request(vm_id, source, actor, key \\ nil) do
    Ledger.transaction(
      fn ->
        action = if source == :user, do: "manage", else: "write"
        vm = Marshall.Access.Authorization.live_vm!(vm_id, actor, action)
        request_locked!(vm, source, actor, key)
      end,
      actor
    )
  end

  # @cc [owner:ghuntley,label:security;recovery] wake-trusted-admission-not-execution
  # Callers MUST hold the VM lock and have freshly checked their specific
  # browser, key, web-publication or peer authority. This function grants only
  # durable machine demand. It MUST join one unfinished wake and leave all
  # execution grants to fresh post-resume admission. Running prompts MUST NOT
  # refresh the idle clock. New suspended demand and successful readiness start
  # a fresh window; running network traffic MUST NOT extend that window.
  @spec request_locked!(
          VirtualMachine.t(),
          source(),
          Marshall.Accounts.User.t() | nil,
          String.t() | nil
        ) :: request_result()
  def request_locked!(vm, source, actor, key \\ nil) do
    unless Marshall.Repo.in_transaction?(),
      do: raise(ArgumentError, "wake requires VM transaction")

    if vm.desired_state == :deleted or vm.archived_at != nil, do: Ledger.rollback(:vm_deleted)

    cond do
      ready?(vm) and source != :user ->
        :already_running

      true ->
        requester = actor && actor.id

        if (source == :user and key) &&
             Ledger.read!(Operation, vm_id: vm.id, requested_by_id: requester, request_key: key) !=
               [],
           do: Ledger.rollback(:idempotency_conflict)

        retained =
          if key && requester,
            do:
              Ledger.read!(WakeRequestKey,
                vm_id: vm.id,
                requested_by_id: requester,
                request_key: key
              ),
            else: []

        case retained do
          [binding] ->
            [wake] = Ledger.read!(WakeRequest, id: binding.wake_request_id)
            wake

          [] ->
            wake =
              case Ledger.read!(WakeRequest, vm_id: vm.id, finished_at: [is_nil: true]) do
                [wake] ->
                  wake

                [] ->
                  Marshall.Compute.Idle.touch_locked!(vm)

                  wake =
                    Ledger.create!(WakeRequest, :request, %{
                      vm_id: vm.id,
                      requested_by_id: requester,
                      request_key: key,
                      source: source,
                      checkpoint_id: checkpoint_id(vm),
                      requested_generation: vm.generation
                    })

                  %{wake_id: wake.id} |> Marshall.Compute.WakeWorker.new() |> Oban.insert!()

                  Ledger.after_commit(fn ->
                    Marshall.Events.emit("vm.wake_requested", vm_id: wake.vm_id, wake_id: wake.id)
                  end)

                  wake
              end

            if key && requester do
              Ledger.create!(WakeRequestKey, :record, %{
                vm_id: vm.id,
                requested_by_id: requester,
                request_key: key,
                wake_request_id: wake.id
              })
            end

            if source == :user and match?(%{administrator: true}, actor) do
              Ledger.create!(Marshall.Accounts.AdminEvent, :record, %{
                actor_id: actor.id,
                target_id: vm.id,
                kind: :vm_lifecycle
              })
            end

            wake
        end
    end
  end

  @doc "Read-only progress. Callers retain responsibility for current access checks."
  @spec status(String.t()) :: status()
  def status(vm_id) do
    case Ledger.read!(VirtualMachine, id: vm_id) do
      [vm] ->
        cond do
          ready?(vm) ->
            {:ready, vm}

          vm.desired_state == :deleted ->
            {:error, :vm_deleted}

          true ->
            case Ledger.read!(WakeRequest, vm_id: vm_id, finished_at: [is_nil: true]) do
              [wake] -> {:pending, wake}
              [] -> {:error, :machine_unavailable}
            end
        end

      [] ->
        {:error, :vm_deleted}
    end
  end

  @spec ready?(VirtualMachine.t()) :: boolean()
  def ready?(vm),
    do:
      vm.desired_state == :running and vm.observed_state == :running and
        Marshall.Compute.RelocationReadinessState.terminal_allowed?(vm)

  @doc "Explicit lifecycle supersession; caller retains the VM lock."
  @spec cancel_locked!(String.t()) :: :ok
  def cancel_locked!(vm_id) do
    for wake <- Ledger.read!(WakeRequest, vm_id: vm_id, finished_at: [is_nil: true]),
        do: finish!(wake, :cancelled, :superseded)

    :ok
  end

  # @cc [owner:ghuntley,label:capacity;recovery] wake-local-before-compatible-relocation
  # Each decision MUST lock all candidate hosts in UUID order before the VM and
  # recheck current demand, physical pause and fresh capacity. Only an admitted
  # reservation may create resume execution. No capacity MUST remain durable
  # waiting, without releasing the checkpoint or exhausting worker retries.
  @spec advance(String.t()) :: {:ok, :waiting | :finished} | {:error, term()}
  def advance(id) do
    Ledger.transaction(fn ->
      hosts =
        Host |> Ledger.read!() |> Enum.sort_by(& &1.id) |> Enum.map(&Ledger.lock!(Host, &1.id))

      case Ledger.read!(WakeRequest, id: id) do
        [] ->
          :finished

        [candidate] ->
          vm = Ledger.lock!(VirtualMachine, candidate.vm_id)
          wake = Ledger.lock!(WakeRequest, id)
          advance_locked!(wake, vm, hosts)
      end
    end)
  end

  @spec advance_locked!(WakeRequest.t(), VirtualMachine.t() | nil, [Host.t()]) ::
          :waiting | :finished
  defp advance_locked!(%{finished_at: finished}, _, _) when not is_nil(finished), do: :finished
  defp advance_locked!(wake, nil, _), do: finish!(wake, :cancelled, :vm_deleted)

  defp advance_locked!(wake, %{desired_state: :deleted}, _),
    do: finish!(wake, :cancelled, :vm_deleted)

  defp advance_locked!(wake, vm, hosts) do
    cond do
      ready?(vm) ->
        finish!(wake, :ready)

      wake.status == :resuming and vm.observed_state == :failed ->
        finish!(wake, :failed, :execution_failed)

      failed_relocation?(wake) ->
        finish!(wake, :failed, :execution_failed)

      Ledger.read!(Relocation, vm_id: vm.id, finished_at: [is_nil: true]) != [] ->
        :waiting

      wake.status in [:pending, :waiting_capacity] and vm.generation > wake.requested_generation ->
        finish!(wake, :cancelled, :superseded)

      Ledger.read!(Operation, vm_id: vm.id, status: [in: [:pending, :acknowledged]]) != [] ->
        :waiting

      wake.status == :resuming ->
        :waiting

      true ->
        admit_execution!(wake, vm, hosts)
    end
  end

  # @cc [owner:ghuntley,label:recovery;capacity] wake-relocation-failure-retains-custody
  # A committed relocation's activation/readiness refusal MUST finish its exact
  # linked wake, without changing relocation authority, checkpoints or holds.
  # Capacity waiting and an unrelated relocation MUST NOT finish that demand.
  @spec failed_relocation?(WakeRequest.t()) :: boolean()
  defp failed_relocation?(%{relocation_id: nil}), do: false

  defp failed_relocation?(wake) do
    case Ledger.read!(Relocation, id: wake.relocation_id) do
      [relocation] ->
        relocation.wake_request_id == wake.id and relocation.vm_id == wake.vm_id and
          relocation.committed_at != nil and
          relocation.phase in [:activation_failed, :readiness_failed]

      [] ->
        false
    end
  end

  @spec admit_execution!(WakeRequest.t(), VirtualMachine.t(), [Host.t()]) :: :waiting | :finished
  defp admit_execution!(wake, vm, hosts) do
    [reservation] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
    host = Enum.find(hosts, &(&1.id == vm.host_id))

    kind =
      if vm.current_checkpoint != nil and vm.observed_state == :paused, do: :resume, else: :start

    cond do
      wake.checkpoint_id != nil and wake.checkpoint_id != checkpoint_id(vm) ->
        finish!(wake, :failed, :checkpoint_unavailable)

      vm.observed_state == :paused and vm.current_checkpoint == nil ->
        finish!(wake, :failed, :checkpoint_unavailable)

      vm.desired_state == :paused and vm.observed_state != :paused ->
        :waiting

      vm.observed_state not in [:paused, :stopped, :failed] ->
        :waiting

      kind == :start and vm.current_checkpoint != nil ->
        finish!(wake, :failed, :checkpoint_unavailable)

      Marshall.Compute.Resize.busy?(vm.id) or
          Marshall.Compute.CloneGuard.lifecycle_busy?(vm.id, kind) ->
        :waiting

      host == nil ->
        wait_capacity!(wake)

      true ->
        wake =
          if kind == :resume and wake.checkpoint_id == nil,
            do:
              Ledger.update!(wake, :advance, %{
                status: :waiting_capacity,
                checkpoint_id: checkpoint_id(vm)
              }),
            else: wake

        case Marshall.Compute.RestartCapacity.check(host, vm, reservation) do
          :fits ->
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
                kind: kind,
                initiator: :wake
              })

            Ledger.update!(wake, :advance, %{status: :resuming, operation_id: operation.id})
            :waiting

          :stale ->
            wait_capacity!(wake)

          :insufficient when kind == :resume ->
            relocate!(wake, vm, hosts)

          :insufficient ->
            wait_capacity!(wake)
        end
    end
  end

  @spec relocate!(WakeRequest.t(), VirtualMachine.t(), [Host.t()]) :: :waiting
  defp relocate!(wake, vm, hosts) do
    case Marshall.Compute.RelocationCapacity.reserve_wake_locked(vm, hosts, wake) do
      {:ok, relocation} ->
        Ledger.update!(wake, :advance, %{status: :relocating, relocation_id: relocation.id})
        :waiting

      {:error, :insufficient_capacity} ->
        wait_capacity!(wake)
    end
  end

  @spec wait_capacity!(WakeRequest.t()) :: :waiting
  defp wait_capacity!(wake) do
    unless wake.status == :waiting_capacity,
      do: Ledger.update!(wake, :advance, %{status: :waiting_capacity})

    :waiting
  end

  @spec finish!(WakeRequest.t(), :ready | :failed | :cancelled, atom() | nil) :: :finished
  defp finish!(wake, status, reason \\ nil) do
    if status == :ready do
      [vm] = Ledger.read!(VirtualMachine, id: wake.vm_id)
      Marshall.Compute.Idle.touch_locked!(vm)
    end

    Ledger.update!(wake, :advance, %{
      status: status,
      failure_reason: reason,
      finished_at: Ledger.now()
    })

    Ledger.after_commit(fn ->
      case status do
        :ready ->
          Marshall.Events.emit("vm.wake_ready", vm_id: wake.vm_id, wake_id: wake.id)

        :failed ->
          Marshall.Events.emit("vm.wake_failed", vm_id: wake.vm_id, wake_id: wake.id)

        :cancelled ->
          Marshall.Events.emit("vm.wake_cancelled", vm_id: wake.vm_id, wake_id: wake.id)
      end
    end)

    :finished
  end

  @spec checkpoint_id(VirtualMachine.t()) :: String.t() | nil
  defp checkpoint_id(%{current_checkpoint: nil}), do: nil
  defp checkpoint_id(vm), do: Map.get(vm.current_checkpoint, "id")
end
