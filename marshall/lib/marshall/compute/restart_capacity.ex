defmodule Marshall.Compute.RestartCapacity do
  @moduledoc "Fresh physical admission for another execution of a retained disk."
  alias Marshall.Compute.{Budget, Host, Ledger, Reservation, StoragePool, VirtualMachine}

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
    now = Ledger.now()

    with true <- host.enabled and host.maintenance_mode == :normal,
         true <- host.inventory["execution_ready"] == true,
         true <- Marshall.Compute.Profiles.host_ready?(vm, host.inventory),
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
