defmodule Marshall.Compute.RestartCapacity do
  @moduledoc "Fresh physical admission for another execution of a retained disk."
  alias Marshall.Compute.{
    Budget,
    Host,
    Ledger,
    Relocation,
    Reservation,
    StoragePool,
    VirtualMachine
  }

  # @cc [owner:ghuntley,label:capacity] restart-full-shape-recheck
  # With the host locked, every new execution MUST fit fresh measured CPU/RAM
  # headroom after other startup holds. Its own previous hold is replaced, never
  # charged twice. Unknown telemetry MUST reject recovery without losing disk.
  @spec fits?(Host.t(), VirtualMachine.t(), Reservation.t()) :: boolean()
  def fits?(host, vm, reservation), do: check(host, vm, reservation) == :fits

  # @cc [owner:ghuntley,label:capacity] restart-capacity-stale-is-not-insufficient
  # check/3 MUST return :stale (not :insufficient) when the host or pool report
  # is merely too old for capacity decisions: slowness is never evidence of a
  # shortfall (ADR-0140). :insufficient means a measured shortfall or an
  # ineligible host. Only :fits admits a restart.
  @spec check(Host.t(), VirtualMachine.t(), Reservation.t()) :: :fits | :stale | :insufficient
  def check(host, vm, reservation) do
    if host.enabled and host.maintenance_mode == :normal,
      do: physical_capacity(host, vm, reservation),
      else: :insufficient
  end

  # @cc [owner:ghuntley,label:security;recovery;capacity] cancelled-evacuation-source-only
  # Caller holds endpoint host locks then the VM lock. Only an uncommitted,
  # revoked cancellation restoring its original running source may use the
  # campaign-bound Evacuations.source_allowed? policy. The current fresh-epoch
  # pause generation and retained source compute hold MUST still match exactly.
  # This exception MUST retain every ordinary physical-capacity/image/checkpoint
  # check and MUST NOT grant generic wake admission on a maintenance host.
  @spec check_source_restoration(Host.t(), VirtualMachine.t(), Reservation.t(), Relocation.t()) ::
          :fits | :stale | :insufficient
  def check_source_restoration(host, vm, reservation, relocation) do
    eligible =
      relocation.preserves_memory and relocation.original_state == :running and
        relocation.vm_id == vm.id and relocation.finished_at == nil and
        relocation.source_restored_at == nil and relocation.cancellation_start_operation_id == nil and
        relocation.wake_request_id == nil and relocation.committed_at == nil and
        relocation.cancellation_requested_at != nil and relocation.source_revoked_at != nil and
        relocation.deletion_requested_at == nil and
        host.id == relocation.source_host_id and
        vm.current_placement_id == relocation.source_placement_id and
        vm.execution_epoch == relocation.destination_epoch and
        vm.generation == relocation.cancellation_stop_generation and
        vm.desired_state == :paused and vm.observed_state == :paused and
        reservation.vm_id == vm.id and reservation.host_id == host.id and
        reservation.placement_id == vm.current_placement_id and reservation.compute_held and
        Marshall.Compute.Evacuations.source_allowed?(host, relocation)

    if eligible, do: physical_capacity(host, vm, reservation), else: :insufficient
  end

  @spec physical_capacity(Host.t(), VirtualMachine.t(), Reservation.t()) ::
          :fits | :stale | :insufficient
  defp physical_capacity(host, vm, reservation) do
    now = Ledger.now()

    with true <- host.inventory["execution_ready"] == true,
         true <- Marshall.Compute.Profiles.host_ready?(vm, host.inventory),
         true <-
           vm.current_checkpoint == nil or
             (OverallsProtocol.NativeAdmission.checkpoint_qualified?(
                vm.image_id,
                host.inventory["checkpoint_image_ids"]
              ) and
                host.inventory["checkpoint_compatibility"] ==
                  vm.current_checkpoint["compatibility"]),
         [pool] <- Ledger.read!(StoragePool, id: reservation.pool_id) do
      if Marshall.Compute.HostLiveness.capacity_fresh?(host.reported_at, now) and
           Marshall.Compute.HostLiveness.capacity_fresh?(pool.reported_at, now) do
        others =
          Ledger.read!(Reservation, host_id: host.id) |> Enum.reject(&(&1.id == reservation.id))

        available = Budget.available(host, pool, others)
        needed = OverallsProtocol.VMShape.reservation(vm)

        if available.vcpu >= needed.vcpu and available.memory_bytes >= needed.memory_bytes,
          do: :fits,
          else: :insufficient
      else
        :stale
      end
    else
      _ -> :insufficient
    end
  end
end
