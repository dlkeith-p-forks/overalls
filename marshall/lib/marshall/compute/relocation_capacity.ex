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
  # destination placement, its single-disk reservation and both slots
  # together or roll back. It MUST NOT change current execution authority, release
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

  # Every relocation stops a running workload for its single full copy
  # (ADR-0155), so evacuating a running workload always needs item approval.
  defp downtime_approval_required?(vm), do: vm.desired_state == :running

  defp prepare!(vm, hosts, source_mode) do
    if Marshall.Compute.Resize.busy?(vm.id), do: Ledger.rollback(:resize_in_progress)

    if Ledger.read!(Relocation, vm_id: vm.id, finished_at: [is_nil: true]) != [],
      do: Ledger.rollback(:relocation_in_progress)

    unless vm.archived_at == nil and vm.desired_state in [:running, :stopped] and
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
    # A stopped full copy needs exactly one disk reservation at the destination
    # (plus compute for a running workload) and no temporary headroom on either
    # endpoint: the stopped source snapshot cannot diverge. The first eligible
    # pool in host/pool UUID order is chosen deterministically.
    {destination, pool} =
      hosts
      |> Enum.reject(&(&1.id == source.id))
      |> Enum.sort_by(& &1.id)
      |> Enum.filter(
        &(eligible_host?(&1, vm, now) and Marshall.Compute.Profiles.host_ready?(vm, &1.inventory) and
            not busy?(&1.id))
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
            if vm.desired_state == :running,
              do: Budget.fits?(available, needed),
              else: available.disk_bytes >= needed.disk_bytes

          if fits, do: {host, pool}
        end)
      end) || Ledger.rollback(:insufficient_capacity)

    %{
      source: source,
      destination: destination,
      pool: pool,
      needed: needed
    }
  end

  defp reserve_new!(vm, hosts, actor, key, campaign \\ nil, item \\ nil) do
    if Marshall.Compute.CloneGuard.vm_busy?(vm.id), do: Ledger.rollback(:clone_in_progress)

    %{source: source, destination: destination, pool: pool, needed: needed} =
      prepare!(vm, hosts, if(campaign, do: :evacuating, else: :normal))

    if not is_nil(campaign) and downtime_approval_required?(vm) and is_nil(item.approved_at),
      do: Ledger.rollback(:downtime_approval_required)

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
        compute_held: vm.desired_state == :running,
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
        original_state: vm.desired_state,
        source_endpoint: source.transfer_endpoint,
        requested_by_id: actor.id,
        request_key: key,
        evacuation_id: if(campaign, do: campaign.id)
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
