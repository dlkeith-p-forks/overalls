defmodule Marshall.Compute.RelocationCapacity do
  @moduledoc "Capacity preparation inside a relocation coordinator transaction; no host effects."
  alias Marshall.Compute.{
    Budget,
    Host,
    Ledger,
    Operation,
    Relocation,
    Reservation,
    StoragePool,
    TransferSlot,
    TransferSlots,
    VirtualMachine,
    WorkloadPlacement
  }

  # @cc [owner:ghuntley,label:concurrency;capacity] relocation-capacity-atomic-pair
  # reserve_locked!/4 requires fresh host records locked in UUID order before the
  # VM row lock, in the caller's transaction. It MUST recheck manage permission,
  # stable VM intent, source ownership, enrolled SSH identities for both endpoints
  # and fresh capacity. A pin does not establish connectivity or a transfer permit.
  # It MUST commit a new
  # destination placement, disk/checkpoint reservations and both transfer slots
  # together or roll back. It MUST NOT change current execution authority, release
  # The globally reserved VM profile/slot MUST remain unchanged across placement
  # handoff, preserving the restored guest IP/MAC without colliding with another
  # active network allocation. It MUST NOT allocate a new slot for a move.
  # source compute/disk or perform host effects. The caller must enqueue durable
  # coordination in that same transaction before accepting a user relocation.
  @spec reserve_locked!(VirtualMachine.t(), [Host.t()], Marshall.Accounts.User.t(), String.t()) ::
          Relocation.t()
  def reserve_locked!(vm, hosts, actor, key) do
    unless Marshall.Repo.in_transaction?(), do: raise(ArgumentError, "transaction required")
    Marshall.Access.Authorization.require!(vm, actor, "manage")

    case Ledger.read!(Relocation, vm_id: vm.id, requested_by_id: actor.id, request_key: key) do
      [existing] -> existing
      [] -> reserve_new!(vm, hosts, actor, key)
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] evacuation-reservation-bound-authority
  # This trusted entry MUST recheck an active persisted campaign and fixed cohort
  # under caller-held sorted host locks. It MUST NOT use the former administrator's
  # current role as durable authority. Only this campaign's source may be evacuating;
  # destinations remain normal. Running workloads MUST have item downtime approval.
  @spec reserve_evacuation_locked!(VirtualMachine.t(), [Host.t()], map(), map()) :: Relocation.t()
  def reserve_evacuation_locked!(vm, hosts, campaign, item) do
    unless Marshall.Repo.in_transaction?(), do: raise(ArgumentError, "transaction required")
    campaign = Ledger.lock!(Marshall.Compute.Evacuation, campaign.id)
    item = Ledger.lock!(Marshall.Compute.EvacuationItem, item.id)

    unless campaign.status == :active and is_nil(campaign.closed_at) and
             item.evacuation_id == campaign.id and
             item.vm_id == vm.id and campaign.host_id == vm.host_id and is_nil(item.relocation_id) and
             is_nil(item.resolved_at) and
             Marshall.Compute.Evacuations.matches?(item, vm),
           do: Ledger.rollback(:invalid_evacuation_authority)

    reserve_new!(vm, hosts, %{id: campaign.requested_by_id}, item.request_key, campaign, item)
  end

  # @cc [owner:ghuntley,label:capacity;product] evacuation-preview-advisory
  # Preview MUST reuse admission's eligibility and Budget/slot selection without
  # allocating, locking capacity or performing host effects. Results are advisory;
  # actual admission MUST repeat selection under current sorted host locks.
  @spec preview(VirtualMachine.t(), [Host.t()], :normal | :evacuating) ::
          {:ok, map()} | {:error, term()}
  def preview(vm, hosts, mode) when mode in [:normal, :evacuating] do
    Ledger.transaction(fn ->
      plan = prepare!(vm, hosts, mode)

      %{
        destination_id: plan.destination.id,
        destination_name: plan.destination.name,
        pool_id: plan.pool.id,
        downtime_approval_required: downtime_approval_required?(vm)
      }
    end)
  end

  # Memory-preserving relocation pauses a running workload for its full copy,
  # so evacuating a running workload still needs downtime approval (ADR-0197).
  defp downtime_approval_required?(vm), do: vm.desired_state == :running

  defp prepare!(vm, hosts, source_mode, wake? \\ false) do
    if Marshall.Compute.Resize.busy?(vm.id), do: Ledger.rollback(:resize_in_progress)

    if Ledger.read!(Relocation, vm_id: vm.id, finished_at: [is_nil: true]) != [],
      do: Ledger.rollback(:relocation_in_progress)

    unless vm.archived_at == nil and vm.desired_state in [:running, :stopped, :paused] and
             vm.observed_state == vm.desired_state and
             vm.execution_epoch < 9_223_372_036_854_775_807,
           do: Ledger.rollback(:workload_not_stable)

    if Enum.any?(
         Ledger.read!(Operation, vm_id: vm.id),
         &(&1.status in [:pending, :acknowledged])
       ),
       do: Ledger.rollback(:workload_not_stable)

    source = Enum.find(hosts, &(&1.id == vm.host_id)) || Ledger.rollback(:source_unavailable)
    [source_pool] = Ledger.read!(StoragePool, id: vm.pool_id)
    [source_reservation] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
    now = Ledger.now()

    unless eligible_host?(source, vm, now, source_mode) and fresh_pool?(source_pool, now) and
             source_reservation.disk_held and source_reservation.temporary_disk_bytes == 0 and
             source_reservation.compute_held == (vm.desired_state == :running),
           do: Ledger.rollback(:source_unavailable)

    if busy?(source.id), do: Ledger.rollback(:transfer_busy)
    needed = OverallsProtocol.VMShape.reservation(vm)

    # @cc [owner:ghuntley,label:capacity] relocation-destination-single-disk
    # Every full copy needs one disk reservation and startup compute when
    # activation runs. Memory-bearing moves MUST hold both immutable checkpoint
    # slots at each endpoint and require exact native compatibility. The first
    # eligible pool in host/pool UUID order wins.
    checkpoint_bytes =
      if vm.desired_state == :stopped,
        do: 0,
        else: 2 * OverallsProtocol.VMShape.checkpoint_bytes(vm.memory_bytes)

    extra_source = max(0, checkpoint_bytes - source_reservation.checkpoint_bytes)

    unless Budget.physical_disk_available(
             source,
             source_pool,
             Ledger.read!(Reservation, host_id: source.id)
           ) >= extra_source,
           do: Ledger.rollback(:insufficient_capacity)

    needed = %{needed | disk_bytes: needed.disk_bytes + checkpoint_bytes}

    compatibility =
      if vm.current_checkpoint,
        do: vm.current_checkpoint["compatibility"],
        else: source.inventory["checkpoint_compatibility"]

    selected =
      hosts
      |> Enum.reject(&(&1.id == source.id))
      |> Enum.sort_by(& &1.id)
      |> Enum.filter(
        &(eligible_host?(&1, vm, now) and Marshall.Compute.Profiles.host_ready?(vm, &1.inventory) and
            not busy?(&1.id) and
            (vm.desired_state == :stopped or
               (is_binary(compatibility) and
                  &1.inventory["checkpoint_compatibility"] == compatibility)))
      )
      |> Enum.find_value(fn host ->
        reservations = Ledger.read!(Reservation, host_id: host.id)

        StoragePool
        |> Ledger.read!(host_id: host.id)
        |> Enum.sort_by(& &1.id)
        |> Enum.filter(&fresh_pool?(&1, now))
        |> Enum.find_value(fn pool ->
          available = Budget.available(host, pool, reservations)

          fits =
            if wake? or vm.desired_state == :running,
              do: Budget.fits?(available, needed),
              else: available.disk_bytes >= needed.disk_bytes

          if fits, do: {host, pool}
        end)
      end)

    case selected do
      {destination, pool} ->
        %{
          source: source,
          destination: destination,
          pool: pool,
          needed: %{needed | disk_bytes: needed.disk_bytes - checkpoint_bytes},
          checkpoint_bytes: checkpoint_bytes
        }

      nil when wake? ->
        nil

      nil ->
        Ledger.rollback(:insufficient_capacity)
    end
  end

  defp reserve_new!(vm, hosts, actor, key, campaign \\ nil, item \\ nil) do
    if Marshall.Compute.CloneGuard.vm_busy?(vm.id), do: Ledger.rollback(:clone_in_progress)

    plan = prepare!(vm, hosts, if(campaign, do: :evacuating, else: :normal))

    if not is_nil(campaign) and downtime_approval_required?(vm) and is_nil(item.approved_at),
      do: Ledger.rollback(:downtime_approval_required)

    allocate!(vm, plan, actor.id, key, campaign && campaign.id, nil)
  end

  # @cc [owner:ghuntley,label:security;capacity] wake-relocation-persisted-demand
  # Only an unfinished persisted wake for this exact paused VM/checkpoint may
  # choose a destination without a manage action. Caller MUST retain sorted host
  # locks and the VM lock. No destination fit returns waiting without allocating.
  @spec reserve_wake_locked(VirtualMachine.t(), [Host.t()], Marshall.Compute.WakeRequest.t()) ::
          {:ok, Relocation.t()} | {:error, :insufficient_capacity}
  def reserve_wake_locked(vm, hosts, wake) do
    wake =
      Ledger.lock!(Marshall.Compute.WakeRequest, wake.id) ||
        Ledger.rollback(:invalid_wake_authority)

    unless wake.vm_id == vm.id and wake.finished_at == nil and vm.observed_state == :paused and
             vm.desired_state == :paused and vm.current_checkpoint != nil and
             wake.checkpoint_id == vm.current_checkpoint["id"],
           do: Ledger.rollback(:invalid_wake_authority)

    if wake_source_available?(vm, hosts) do
      case prepare!(vm, hosts, :normal, true) do
        nil -> {:error, :insufficient_capacity}
        plan -> {:ok, allocate!(vm, plan, nil, "wake:" <> wake.id, nil, wake)}
      end
    else
      {:error, :insufficient_capacity}
    end
  end

  # Capacity demand MUST wait durably when its transfer endpoint or backing
  # headroom is temporarily unavailable. These reads share the caller's host/VM
  # locks with preparation, so routine shortages cannot exhaust worker retries.
  @spec wake_source_available?(VirtualMachine.t(), [Host.t()]) :: boolean()
  defp wake_source_available?(vm, hosts) do
    with %Host{} = source <- Enum.find(hosts, &(&1.id == vm.host_id)),
         [pool] <- Ledger.read!(StoragePool, id: vm.pool_id),
         [hold] <- Ledger.read!(Reservation, placement_id: vm.current_placement_id) do
      now = Ledger.now()
      needed = 2 * OverallsProtocol.VMShape.checkpoint_bytes(vm.memory_bytes)

      eligible_host?(source, vm, now) and fresh_pool?(pool, now) and
        not busy?(source.id) and hold.disk_held and not hold.compute_held and
        hold.temporary_disk_bytes == 0 and
        vm.execution_epoch < 9_223_372_036_854_775_807 and
        Budget.physical_disk_available(
          source,
          pool,
          Ledger.read!(Reservation, host_id: source.id)
        ) >=
          max(0, needed - hold.checkpoint_bytes)
    else
      _ -> false
    end
  end

  @spec allocate!(
          VirtualMachine.t(),
          map(),
          String.t() | nil,
          String.t(),
          String.t() | nil,
          Marshall.Compute.WakeRequest.t() | nil
        ) :: Relocation.t()
  defp allocate!(vm, plan, actor_id, key, campaign_id, wake) do
    %{
      source: source,
      destination: destination,
      pool: pool,
      needed: needed,
      checkpoint_bytes: checkpoint_bytes
    } = plan

    if checkpoint_bytes > 0 do
      [source_hold] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
      Ledger.update!(source_hold, :hold_checkpoint, %{checkpoint_bytes: checkpoint_bytes})
    end

    placement =
      Ledger.create!(WorkloadPlacement, :allocate, %{
        vm_id: vm.id,
        host_id: destination.id,
        pool_id: pool.id
      })

    Ledger.create!(
      Reservation,
      :reserve,
      Map.merge(needed, %{
        vm_id: vm.id,
        placement_id: placement.id,
        host_id: destination.id,
        pool_id: pool.id,
        compute_held: wake != nil or vm.desired_state == :running,
        checkpoint_bytes: checkpoint_bytes,
        temporary_disk_bytes: 0
      })
    )

    relocation =
      Ledger.create!(Relocation, :record, %{
        vm_id: vm.id,
        source_placement_id: vm.current_placement_id,
        destination_placement_id: placement.id,
        source_host_id: source.id,
        destination_host_id: destination.id,
        source_epoch: vm.execution_epoch,
        destination_epoch: vm.execution_epoch + 1,
        original_state: if(wake, do: :running, else: vm.desired_state),
        preserves_memory: vm.desired_state != :stopped,
        wake_request_id: wake && wake.id,
        source_endpoint: source.transfer_endpoint,
        requested_by_id: actor_id,
        request_key: key,
        evacuation_id: campaign_id
      })

    TransferSlots.occupy_locked!(relocation)
    relocation
  end

  defp eligible_host?(host, vm, now, mode \\ :normal),
    do:
      host.enabled and host.maintenance_mode == mode and
        match?({:ok, _}, OverallsProtocol.TransferSSH.endpoint(host.transfer_endpoint)) and
        host.architecture == vm.architecture and host.inventory["execution_ready"] == true and
        Marshall.Compute.HostLiveness.capacity_fresh?(host.reported_at, now)

  defp fresh_pool?(pool, now),
    do:
      pool.backend == :zfs and
        Marshall.Compute.HostLiveness.capacity_fresh?(pool.reported_at, now) and
        pool.free_bytes >= pool.overhead_bytes

  defp busy?(host),
    do: Ledger.read!(TransferSlot, host_id: host, released_at: [is_nil: true]) != []
end
