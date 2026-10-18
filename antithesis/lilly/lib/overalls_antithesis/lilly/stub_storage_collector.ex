defmodule OverallsAntithesis.Lilly.StubStorageCollector do
  @moduledoc """
  STUB storage collector for the container guest-lifecycle variant.

  The hosted container has no ZFS, so each configured pool is reported with a
  fixed synthetic size and no allocation credit. Compute headroom is limited to
  free guest-vmm slots observed in its live process inventory and capped by this
  container's measured cgroup limits. None of this is native ZFS, KVM or
  capacity evidence; it only lets Marshall admit one emulated TCG guest.
  """
  alias Lilly.Host.{Image, Inventory, Pool}
  alias OverallsAntithesis.Lilly.{Collector, GuestExecutor}

  # One emulated QEMU TCG placement per guest-vmm (deployment topology).
  @slots 1
  @slot_millicores 1000
  # Guest RAM plus the VMM overhead admission reserves for each placement.
  @slot_memory_bytes OverallsProtocol.VMShape.host_memory(2_147_483_648)
  # Fixed STUB pool size. It is not a measured filesystem or ZFS dataset.
  @stub_pool_bytes 1_099_511_627_776
  @interval_us 1_000_000

  @type guest_entry :: %{required(String.t()) => term()}
  @type limits :: %{
          required(:effective_cores) => pos_integer(),
          required(:effective_memory_bytes) => pos_integer(),
          optional(atom()) => term()
        }

  # @cc [owner:ghuntley,label:capacity;verification] stub-storage-is-labelled-synthetic
  # The stub variant MUST report only configured controlled pools, a fixed
  # synthetic pool size with zero usage and no allocation credit, and compute
  # headroom no larger than free guest-vmm slots or the measured cgroup limits.
  # An unavailable guest inventory or cgroup measurement MUST withhold the
  # report rather than report zero or synthetic headroom.
  @spec sample(
          [Pool.t()],
          Path.t(),
          Lilly.Host.Collector.previous() | nil,
          pos_integer(),
          [Image.t()],
          map(),
          map()
        ) ::
          {:ok, OverallsProtocol.report(), Lilly.Host.Collector.previous()} | {:error, atom()}
  def sample(pools, _cgroup_path, _previous, sequence, images, coverage, _native_io) do
    with true <- Pool.distinct?(pools),
         true <- pools != [] and Enum.all?(pools, &(&1.backend == :controlled)),
         {:ok, inventory} <- Inventory.read(),
         {:ok, limits} <-
           Collector.measured_limits("/sys/fs/cgroup", "/proc/self/cgroup", inventory),
         {:ok, guests} <- GuestExecutor.inventory() do
      report =
        report(pools, limits, inventory.architecture, sequence, images, coverage, guests)

      {:ok, report, %{usage: nil}}
    else
      _ -> {:error, :collection_failed}
    end
  end

  @doc "Pure report construction from measured limits and an observed guest inventory."
  @spec report(
          [Pool.t()],
          limits(),
          String.t(),
          pos_integer(),
          [Image.t()],
          map(),
          [guest_entry()]
        ) :: OverallsProtocol.report()
  def report(pools, limits, architecture, sequence, images, coverage, guests) do
    # Any placement that is not positively stopped occupies its slot.
    occupied = Enum.count(guests, &(&1["state"] != "stopped"))
    free = max(0, @slots - occupied)

    %{
      capacity: %{
        "version" => 1,
        "cpu_headroom_millicores" => min(free * @slot_millicores, limits.effective_cores * 1000),
        "memory_headroom_bytes" => min(free * @slot_memory_bytes, limits.effective_memory_bytes),
        "interval_us" => @interval_us,
        "covered" => covered(coverage, guests)
      },
      sequence: sequence,
      sampled_at: DateTime.utc_now(),
      effective_cores: limits.effective_cores,
      effective_memory_bytes: limits.effective_memory_bytes,
      inventory: %{
        "architecture" => architecture,
        "images" => Image.available_ids(images),
        "execution_ready" => false,
        "terminal_protocol" => 0,
        "inception_image_id" => nil
      },
      pools: Enum.map(pools, &stub_pool/1)
    }
  end

  @doc "Whether a report pool entry is exactly this module's fixed synthetic stub."
  @spec stub_pool?(Pool.t(), term()) :: boolean()
  def stub_pool?(pool, entry), do: entry == stub_pool(pool)

  @spec stub_pool(Pool.t()) :: OverallsProtocol.pool()
  defp stub_pool(pool) do
    %{
      id: pool.id,
      total_bytes: @stub_pool_bytes,
      free_bytes: @stub_pool_bytes,
      storage: Map.merge(pool.storage, %{used_bytes: 0, quota_bytes: nil}),
      allocations: %{}
    }
  end

  # A Lilly capacity proof is kept only for a placement the guest-vmm inventory
  # currently holds stopped, or live with the same epoch and generation.
  @spec covered(map(), [guest_entry()]) :: map()
  defp covered(coverage, guests) do
    Map.filter(coverage, fn {id, proof} ->
      Enum.any?(guests, fn entry ->
        entry["placement_id"] == id and
          (entry["state"] == "stopped" or
             (entry["live"] == true and is_map(proof) and
                entry["execution_epoch"] == proof["execution_epoch"] and
                entry["generation"] == proof["generation"]))
      end)
    end)
  end
end
