defmodule Marshall.Compute.Budget do
  @moduledoc "Physical headroom less outstanding startup and relocation holds."
  @type request :: %{vcpu: pos_integer(), memory_bytes: pos_integer(), disk_bytes: pos_integer()}
  @type available :: %{
          vcpu: non_neg_integer(),
          memory_bytes: non_neg_integer(),
          disk_bytes: non_neg_integer()
        }

  # @cc [owner:ghuntley,label:capacity] usage-headroom-with-startup-holds
  # Available resources MUST use known measured headroom and subtract outstanding
  # startup holds once across all host pools. Settled virtual promises MUST NOT
  # consume physical admission budget. Missing usage withholds new admission.
  @spec available(map(), map(), [map()]) :: available()
  def available(host, pool, reservations) do
    case Map.get(host, :capacity) do
      %{"version" => 1} = usage ->
        pending = compute_holds(host, reservations)

        %{
          vcpu:
            max(
              0,
              div(usage["cpu_headroom_millicores"], 1000) - host.overhead_cores -
                pending.vcpu
            ),
          memory_bytes:
            max(
              0,
              usage["memory_headroom_bytes"] - host.overhead_memory_bytes -
                pending.memory_bytes
            ),
          disk_bytes: physical_disk_available(host, pool, reservations)
        }

      _ ->
        %{vcpu: 0, memory_bytes: 0, disk_bytes: 0}
    end
  end

  # @cc [owner:ghuntley,label:capacity] physical-disk-pending-growth
  # Physical headroom MUST subtract pending disk creation and temporary copy
  # holds and both checkpoint slots. Only audited physical bytes of this exact
  # placement's matching disk/checkpoint category may offset its own hold.
  # Settled disk size and compression MUST NOT add physical credit or cap logical
  # assignments. Temporary holds on settled disks remain conservatively charged.
  @spec physical_disk_available(map(), map(), [map()]) :: non_neg_integer()
  def physical_disk_available(host, pool, reservations) do
    holds = disk_holds(host, pool, reservations)
    max(0, pool.free_bytes - pool.overhead_bytes - holds.pending_bytes)
  end

  # @cc [owner:ghuntley,label:capacity;observability] budget-explanation-shared-arithmetic
  # Explanations MUST reuse admission's hold and availability arithmetic, including
  # whole-core rounding, cross-pool startup compute, placement-limited disk credit,
  # temporary copy holds and pending resize bytes. Missing capacity MUST remain
  # unknown while admission stays withheld; settled virtual promises are not usage.
  @spec explain(map(), map(), [map()]) :: map()
  def explain(host, pool, reservations) do
    usage =
      case Map.get(host, :capacity) do
        %{"version" => 1} = value -> value
        _ -> nil
      end

    %{
      capacity_known: not is_nil(usage),
      effective_cores: Map.get(host, :effective_cores),
      effective_memory_bytes: Map.get(host, :effective_memory_bytes),
      measured_cpu_headroom_millicores: if(usage, do: usage["cpu_headroom_millicores"]),
      measured_memory_headroom_bytes: if(usage, do: usage["memory_headroom_bytes"]),
      overhead_cores: host.overhead_cores,
      overhead_memory_bytes: host.overhead_memory_bytes,
      startup_compute: compute_holds(host, reservations),
      disk:
        Map.merge(disk_holds(host, pool, reservations), %{
          free_bytes: pool.free_bytes,
          overhead_bytes: pool.overhead_bytes
        }),
      available: available(host, pool, reservations)
    }
  end

  defp compute_holds(host, reservations) do
    pending =
      Enum.filter(
        reservations,
        &(&1.host_id == host.id and &1.compute_held and Map.get(&1, :startup_compute_held, true))
      )

    %{vcpu: sum(pending, :vcpu), memory_bytes: sum(pending, :memory_bytes)}
  end

  defp disk_holds(host, pool, reservations) do
    values =
      Enum.reduce(
        reservations,
        %{
          creation_bytes: 0,
          materialized_credit_bytes: 0,
          temporary_bytes: 0,
          resize_bytes: 0,
          checkpoint_bytes: 0,
          checkpoint_credit_bytes: 0
        },
        fn reservation, total ->
          if reservation.host_id == host.id and reservation.pool_id == pool.id do
            startup = reservation.disk_held and Map.get(reservation, :startup_disk_held, true)
            disk = if startup, do: reservation.disk_bytes, else: 0

            credit =
              if startup,
                do: min(Map.get(pool.allocations, reservation.placement_id, 0), disk),
                else: 0

            checkpoint = Map.get(reservation, :checkpoint_bytes, 0)

            checkpoint_credit =
              min(
                checkpoint,
                Map.get(Map.get(pool, :checkpoint_allocations, %{}), reservation.placement_id, 0)
              )

            %{
              creation_bytes: total.creation_bytes + disk,
              materialized_credit_bytes: total.materialized_credit_bytes + credit,
              temporary_bytes: total.temporary_bytes + reservation.temporary_disk_bytes,
              checkpoint_bytes: total.checkpoint_bytes + checkpoint,
              checkpoint_credit_bytes: total.checkpoint_credit_bytes + checkpoint_credit,
              resize_bytes: total.resize_bytes + Map.get(reservation, :pending_disk_bytes, 0)
            }
          else
            total
          end
        end
      )

    Map.put(
      values,
      :pending_bytes,
      values.creation_bytes - values.materialized_credit_bytes + values.temporary_bytes +
        values.resize_bytes + values.checkpoint_bytes - values.checkpoint_credit_bytes
    )
  end

  # @cc [owner:ghuntley,label:capacity] budget-all-dimensions-fit
  # fits? MUST return true only when all three requested dimensions are positive
  # integers no greater than their corresponding available capacities.
  @spec fits?(available(), request()) :: boolean()
  def fits?(available, request) do
    Enum.all?([:vcpu, :memory_bytes, :disk_bytes], fn key ->
      requested = Map.fetch!(request, key)
      is_integer(requested) and requested > 0 and requested <= Map.fetch!(available, key)
    end)
  end

  defp sum(records, field), do: Enum.reduce(records, 0, &(&2 + Map.fetch!(&1, field)))
end
