defmodule OverallsAntithesis.Lilly.StubStorageHealth do
  @moduledoc """
  Execution-readiness gate for the container STUB-storage guest variant.

  It requires the labelled stub report and a live guest-vmm preflight. It is
  not the integrated host's native ZFS gate and claims no native capacity.
  """
  alias OverallsAntithesis.Lilly.{GuestRPC, StubStorageCollector}
  alias OverallsProtocol.{Capacity, ImageManifest}
  alias Lilly.Control.Config

  @state_root "/var/lib/overalls-tcg"

  # @cc [owner:ghuntley,label:capacity;verification] stub-readiness-needs-guest-preflight
  # Stub execution readiness MUST require a valid capacity value, every
  # configured controlled pool reported as the fixed stub, a verified advertised
  # image equal to the guest-vmm image, and a successful guest-vmm inventory and
  # state-writability health check. Missing evidence MUST refuse readiness.
  @spec ready?(Config.t(), OverallsProtocol.report()) :: boolean()
  def ready?(config, report) do
    with true <- is_map(report.capacity) and Capacity.valid?(report.capacity),
         true <- stub_pools?(config.pools, report.pools),
         %{"images" => images} when is_list(images) <- report.inventory,
         {:ok,
          %{
            "state" => "ok",
            "image_id" => image,
            "inventory_valid" => true,
            "state_writable" => true,
            "state_root" => @state_root
          } = health} <- GuestRPC.call(%{"operation" => "health"}),
         true <- map_size(health) == 5 and ImageManifest.id?(image),
         true <- image in images do
      true
    else
      _ -> false
    end
  end

  @spec stub_pools?([Lilly.Host.Pool.t()], term()) :: boolean()
  defp stub_pools?(pools, entries) when is_list(entries) and pools != [] do
    length(pools) == length(entries) and
      Enum.all?(pools, fn pool ->
        pool.backend == :controlled and
          Enum.any?(entries, &StubStorageCollector.stub_pool?(pool, &1))
      end)
  end

  defp stub_pools?(_, _), do: false
end
