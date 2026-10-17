defmodule Marshall.Compute.Lifecycle do
  @moduledoc "User lifecycle intent, serialized with host outcomes and capacity reservations."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    Host,
    Ledger,
    Operation,
    Relocation,
    RelocationDeletion,
    RelocationGuard,
    Reservation,
    VirtualMachine
  }

  alias Marshall.Accounts.AdminEvent

  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:security] lifecycle-recheck-after-lock
  # Lifecycle requests MUST recheck current manage permission after obtaining the
  # VM lock, including when authorization succeeded before waiting for that lock.

  # @cc [owner:ghuntley,label:concurrency] lifecycle-generation-transaction
  # A new lifecycle request MUST commit the new generation, cancellation of old
  # pending/acknowledged operations, lifecycle transition and new operation/job
  # together. Reusing its actor/VM/key MUST return the existing same-kind operation
  # or reject a changed kind without advancing the generation.

  # @cc [owner:ghuntley,label:concurrency] lifecycle-relocation-exclusion
  # Start/stop may proceed on a restored source or ready committed destination
  # while cleanup remains pending. Delete locks both relocation endpoints and
  # records all-copy reclamation through its coordinator. After taking
  # the VM lock, lifecycle MUST reject a placement/epoch change since host lookup
  # rather than mutate capacity under the old host lock. Exact retries may return
  # their existing operation without changing relocation or execution authority.
  # An unfinished resize MUST reject every new lifecycle intent, including delete;
  # allowing lifecycle on a ready relocation MUST NOT bypass resize exclusion.
  @impl true
  def run(input, _options, context), do: execute(input.arguments, %{actor: context.actor})

  @doc "Trusted account cleanup only; the durable deletion is re-read before authorization."
  @spec delete_for_account(Marshall.Accounts.UserDeletion.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def delete_for_account(deletion, vm_id) do
    execute(
      %{vm_id: vm_id, kind: :delete, idempotency_key: deletion.id},
      %{actor: %Marshall.Accounts.User{id: deletion.requested_by_id}, deletion_id: deletion.id}
    )
  end

  @doc "Narrow automatic start for a prompt admitted under current VM write access."
  # @cc [owner:ghuntley,label:security;capacity] lifecycle-agent-wake-narrow
  # A prompt may start only its current VM and only for a current write-capable
  # user. A physically stopped or failed VM MUST receive a fresh start even
  # when its desired state is already running. It MUST retain host-before-VM
  # capacity locks and create agent provenance without general stop/delete authority.
  @spec wake_for_prompt(String.t(), Marshall.Accounts.User.t(), String.t()) ::
          {:ok, Operation.t() | :already_running} | {:error, term()}
  def wake_for_prompt(vm_id, actor, request_key) do
    execute(
      %{vm_id: vm_id, kind: :start, idempotency_key: request_key},
      %{actor: actor, agent_wake?: true}
    )
  end

  defp execute(request, context) do
    result =
      Ledger.transaction(
        fn ->
          Ecto.Adapters.SQL.query!(
            Marshall.Repo,
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            ["lifecycle:#{context.actor.id}:#{request.vm_id}:#{request.idempotency_key}"],
            log: false
          )

          vm = find_vm!(request.vm_id)
          authorize!(vm, context)
          authority = {vm.current_placement_id, vm.execution_epoch}

          endpoint_ids =
            if request.kind == :delete do
              Ledger.read!(Relocation, vm_id: vm.id, finished_at: [is_nil: true])
              |> Enum.flat_map(&[&1.source_host_id, &1.destination_host_id])
            else
              []
            end

          hosts =
            Enum.map(Enum.sort(Enum.uniq([vm.host_id | endpoint_ids])), &Ledger.lock!(Host, &1))

          host = Enum.find(hosts, &(&1.id == vm.host_id))
          vm = find_vm!(vm.id, true)
          authorize!(vm, context)

          unless vm.host_id == host.id and
                   {vm.current_placement_id, vm.execution_epoch} == authority,
                 do: Ledger.rollback(:placement_changed)

          case Ledger.read!(Operation,
                 vm_id: vm.id,
                 requested_by_id: context.actor.id,
                 request_key: request.idempotency_key
               ) do
            [operation] ->
              if operation.kind == request.kind,
                do: operation,
                else: Ledger.rollback(:idempotency_conflict)

            [] ->
              if context[:agent_wake?] == true and vm.desired_state == :running and
                   vm.observed_state not in [:stopped, :failed] do
                {:already_running, vm}
              else
                enqueue_locked!(vm, host, hosts, request, context)
              end
          end
        end,
        context.actor
      )

    case result do
      {:ok, {:already_running, _vm}} ->
        {:ok, :already_running}

      {:ok, operation} ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("vm.lifecycle_requested",
            vm_id: operation.vm_id,
            operation_id: operation.id
          )
        end

        {:ok, operation}

      {:error, reason} when is_atom(reason) ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("vm.lifecycle_refused",
            vm_id: vm_id(request),
            reason: reason
          )
        end

        {:error, Marshall.Compute.Error.exception(reason: reason)}

      error ->
        error
    end
  end

  defp enqueue_locked!(vm, host, hosts, request, context) do
    if Marshall.Compute.CloneGuard.lifecycle_busy?(vm.id, request.kind),
      do: Ledger.rollback(:clone_in_progress)

    if Marshall.Compute.Resize.busy?(vm.id), do: Ledger.rollback(:resize_in_progress)

    if request.kind != :delete and RelocationGuard.lifecycle_busy?(vm, request.kind),
      do: Ledger.rollback(:relocation_in_progress)

    if vm.archived_at != nil or vm.desired_state == :deleted,
      do: Ledger.rollback(:vm_deleted)

    relocation =
      if request.kind == :delete,
        do: RelocationDeletion.active_locked!(vm, Enum.map(hosts, & &1.id))

    [reservation] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
    if request.kind == :start, do: reserve_start!(host, vm, reservation)
    cancel_operations!(vm.id)

    vm =
      Ledger.intent!(vm, %{
        generation: next_generation!(vm),
        desired_state: desired(request.kind),
        crash_restart_times: []
      })

    operation =
      Ledger.create!(Operation, :enqueue, %{
        placement_id: vm.current_placement_id,
        execution_epoch: vm.execution_epoch,
        vm_id: vm.id,
        generation: vm.generation,
        requested_by_id: context.actor.id,
        kind: request.kind,
        request_key: request.idempotency_key,
        initiator: if(context[:agent_wake?], do: :agent, else: :user)
      })

    audit_admin!(context.actor, vm.id, :vm_lifecycle)

    if relocation,
      do: RelocationDeletion.request_locked!(relocation, operation, context.actor)

    operation
  end

  defp vm_id(%{vm_id: id}), do: if(OverallsProtocol.uuid?(id), do: id, else: nil)

  # Administrator lifecycle requests are recorded inside the same transaction
  # as the durable operation so the audit cannot claim an action that rolled back.
  defp audit_admin!(%{administrator: true} = actor, target_id, kind) do
    Ledger.create!(AdminEvent, :record, %{actor_id: actor.id, target_id: target_id, kind: kind})
    :ok
  end

  defp audit_admin!(_, _, _), do: :ok

  # @cc [owner:ghuntley,label:product] lifecycle-maintenance-provenance
  # With the host and VM locked, a drain stop MUST target a running intent on the
  # drain's host, record maintenance provenance and drain ID without impersonating
  # a user, and retain capacity until its matching physical stop outcome. An
  # unfinished relocation MUST reject the stop before changing intent.
  @doc "Trusted coordinators hold the host lock before changing its VM intent."
  @spec stop_for_drain_locked!(VirtualMachine.t(), Marshall.Compute.HostDrain.t()) ::
          Operation.t()
  def stop_for_drain_locked!(vm, drain) do
    if RelocationGuard.vm_busy?(vm.id), do: Ledger.rollback(:relocation_in_progress)

    unless vm.host_id == drain.host_id and vm.desired_state == :running,
      do: Ledger.rollback(:invalid_drain_intent)

    cancel_operations!(vm.id)

    vm =
      Ledger.intent!(vm, %{
        generation: next_generation!(vm),
        desired_state: :stopped,
        crash_restart_times: []
      })

    Ledger.create!(Operation, :enqueue, %{
      placement_id: vm.current_placement_id,
      execution_epoch: vm.execution_epoch,
      vm_id: vm.id,
      generation: vm.generation,
      kind: :stop,
      initiator: :maintenance,
      host_drain_id: drain.id
    })
  end

  @doc "Trusted coordinators hold the host lock before changing its VM intent."
  # @cc [owner:ghuntley,label:recovery] lifecycle-preserves-independent-copy-cleanup
  # cancel_operations!/1 MUST retain any exact source-deletion operation bound to
  # a durable relocation cleanup obligation. Ordinary lifecycle/recovery on the
  # authoritative placement MUST NOT cancel physical cleanup of another copy.
  @spec cancel_operations!(String.t()) :: :ok
  def cancel_operations!(vm_id) do
    for operation <- Ledger.read!(Operation, vm_id: vm_id),
        operation.status in [:pending, :acknowledged],
        not Marshall.Compute.RelocationCleanup.operation_allowed?(operation),
        do: Ledger.update!(operation, :cancel, %{})

    :ok
  end

  # @cc [owner:ghuntley,label:recovery] lifecycle-generation-never-wraps
  # A generation MUST increase strictly; reaching the signed 64-bit maximum MUST
  # abort the transaction instead of wrapping or reusing an earlier generation.
  @spec next_generation!(VirtualMachine.t()) :: pos_integer()
  def next_generation!(vm) do
    if vm.generation >= 9_223_372_036_854_775_807, do: Ledger.rollback(:generation_exhausted)
    vm.generation + 1
  end

  defp find_vm!(id, lock \\ false) do
    query =
      VirtualMachine
      |> Ash.Query.for_read(:history, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(id == ^id)

    query = if lock, do: Ash.Query.lock(query, :for_update), else: query
    Ash.read_one!(query, actor: SystemActor.compute()) || Ledger.rollback(:forbidden)
  end

  defp authorize!(vm, %{deletion_id: id}) do
    case Ledger.read!(Marshall.Accounts.UserDeletion, id: id) do
      [%{user_id: user_id, completed_at: nil}] when user_id == vm.owner_id ->
        unless match?(%{deleted_at: %DateTime{}}, Marshall.Accounts.Security.current(user_id)),
          do: Ledger.rollback(:forbidden)

      _ ->
        Ledger.rollback(:forbidden)
    end
  end

  defp authorize!(vm, %{actor: actor, agent_wake?: true}),
    do: Marshall.Access.Authorization.require!(vm, actor, "write")

  defp authorize!(vm, %{actor: actor}),
    do: Marshall.Access.Authorization.require!(vm, actor, "manage")

  # @cc [owner:ghuntley,label:capacity] lifecycle-reacquire-compute
  # Restart MUST require the retained disk and its portable boot bundle on a
  # fresh normal-mode execution-ready host. Every new start must reacquire
  # guest-plus-VMM startup capacity under the host lock before accepting new intent;
  # exhaustion MUST leave the prior generation and retained allocations intact.
  defp reserve_start!(host, vm, reservation) do
    unless host.enabled and host.maintenance_mode == :normal and
             Map.get(host.inventory, "execution_ready") == true and
             Marshall.Compute.HostLiveness.capacity_fresh?(host.reported_at, Ledger.now()),
           do: Ledger.rollback(:host_unavailable)

    unless reservation.disk_held, do: Ledger.rollback(:disk_not_reserved)

    unless Marshall.Compute.RestartCapacity.fits?(host, vm, reservation),
      do: Ledger.rollback(:insufficient_capacity)

    needed = OverallsProtocol.VMShape.reservation(vm)
    Ledger.update!(reservation, :hold_compute, %{memory_bytes: needed.memory_bytes})
  end

  defp desired(:start), do: :running
  defp desired(:stop), do: :stopped
  defp desired(:delete), do: :deleted
end
