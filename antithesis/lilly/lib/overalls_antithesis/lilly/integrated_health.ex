defmodule OverallsAntithesis.Lilly.IntegratedHealth do
  @moduledoc "Measured guest-vmm and native capacity gate for the integrated host variant."

  alias OverallsAntithesis.Lilly.GuestRPC
  alias OverallsProtocol.{Capacity, ImageManifest, Storage}
  alias Lilly.Control.Config

  # @cc [owner:ghuntley,label:capacity;verification] integrated-readiness-measured
  # Execution readiness MUST require a fresh complete native capacity sample,
  # every configured ZFS pool with measured allocation credit, a verified
  # advertised image matching the immutable guest-vmm image, and a successful
  # guest-vmm inventory/state writability preflight. Missing evidence refuses.
  # Private Ziggy/Audi readiness MUST be checked at the stopped-guest launch or
  # restart effect in GuestExecutor, as production Executor does; it MUST NOT
  # block a measured host report and create a host-token bootstrap cycle.
  @spec ready?(Config.t(), OverallsProtocol.report()) :: boolean()
  def ready?(config, report) do
    with true <- is_map(report.capacity) and Capacity.valid?(report.capacity),
         true <- measured_pools?(config.pools, report.pools),
         %{"images" => images} when is_list(images) <- report.inventory,
         {:ok,
          %{
            "state" => "ok",
            "image_id" => image,
            "inventory_valid" => true,
            "state_writable" => true,
            "state_root" => "/pool/guest-emulator"
          } = health} <- GuestRPC.call(%{"operation" => "health"}),
         true <- map_size(health) == 5 and ImageManifest.id?(image),
         true <- image in images do
      true
    else
      _ -> false
    end
  end

  @spec measured_pools?([Lilly.Host.Pool.t()], [OverallsProtocol.pool()]) :: boolean()
  defp measured_pools?(pools, entries) when is_list(entries) and pools != [] do
    length(pools) == length(entries) and
      Enum.all?(pools, fn pool ->
        pool.backend == :zfs and
          Enum.any?(entries, fn
            %{
              id: id,
              storage: storage,
              total_bytes: total,
              free_bytes: free,
              allocations: allocations
            } ->
              id == pool.id and is_map(storage) and
                Map.take(storage, [:backend, :zpool_guid, :dataset_guid, :dataset]) ==
                  pool.storage and
                positive?(total) and nonnegative?(free) and free <= total and
                Storage.coherent?(storage, total, free) and is_map(allocations)

            _ ->
              false
          end)
      end)
  end

  defp measured_pools?(_, _), do: false

  @spec positive?(term()) :: boolean()
  defp positive?(value), do: is_integer(value) and value > 0

  @spec nonnegative?(term()) :: boolean()
  defp nonnegative?(value), do: is_integer(value) and value >= 0
end
