defmodule Marshall.Compute.StartupHolds do
  @moduledoc "Reconcile provisional capacity only against authenticated, current physical coverage."
  alias Marshall.Compute.{Host, Ledger, PhysicalOutcome, Reservation, VirtualMachine}

  # @cc [owner:ghuntley,label:capacity] startup-proof-current-generation
  # Under the host lock, settlement MUST match the current VM placement, epoch,
  # generation and an already authenticated physical outcome. Disk settlement
  # additionally requires this report's owned allocation. It MUST NOT release
  # lifecycle ownership, use a missing pool or trust an unrecorded peer proof.
  # Clone interruption reserves a future source restart: observations of the
  # pre-capture execution MUST NOT settle that hold before restoration completes.
  @spec settle_locked!(Host.t(), [map()]) :: :ok
  def settle_locked!(%{capacity: nil}, _), do: :ok

  def settle_locked!(host, pools) do
    covered = host.capacity["covered"]

    for reservation <- Ledger.read!(Reservation, host_id: host.id),
        (reservation.compute_held and reservation.startup_compute_held) or
          (reservation.disk_held and reservation.startup_disk_held),
        proof = covered[reservation.placement_id],
        proof != nil do
      with [vm] <- Ledger.history!(VirtualMachine, id: reservation.vm_id),
           true <-
             vm.archived_at == nil and vm.current_placement_id == reservation.placement_id and
               vm.execution_epoch == proof["execution_epoch"] and
               vm.generation == proof["generation"],
           [outcome] <- Ledger.read!(PhysicalOutcome, id: proof["outcome_id"], host_id: host.id),
           observation = outcome.observation,
           true <-
             observation["vm_id"] == vm.id and observation["sequence"] == vm.outcome_sequence and
               observation["placement_id"] == reservation.placement_id and
               observation["execution_epoch"] == vm.execution_epoch and
               observation["generation"] == vm.generation do
        pool = Enum.find(pools, &(&1.id == reservation.pool_id))

        compute =
          proof["compute"] and observation["state"] == "running" and
            not Marshall.Compute.CloneGuard.lifecycle_busy?(vm.id, :start)

        disk =
          proof["disk"] and observation["state"] in ["running", "stopped"] and
            observation["disk_present"] == true and pool != nil and pool.reported_at != nil and
            Map.has_key?(pool.allocations, reservation.placement_id)

        Ledger.update!(reservation, :settle_usage, %{
          startup_compute_held: reservation.startup_compute_held and not compute,
          startup_disk_held: reservation.startup_disk_held and not disk
        })
      else
        _ -> :ok
      end
    end

    :ok
  end
end
