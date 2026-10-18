defmodule OverallsAntithesis.Lilly.Collector do
  @moduledoc """
  Hosted Control report with measured cgroup limits. Storage is explicitly
  unavailable unless the `admission-stub` profile selects the harness-only
  stub substrate (`OverallsAntithesis.Lilly.StubStorage`), which is not ZFS.
  """
  alias Lilly.Host.{Image, Inventory, Limits, Pool, Usage}
  alias OverallsAntithesis.Lilly.StubStorage

  # @cc [owner:ghuntley,label:capacity] hosted-capacity-never-fabricated
  # Synthetic pool identity cannot supply native capacity or physical headroom.
  # Only the explicitly selected harness stub substrate may supply stub (never
  # native) pool totals, and it is reported as configured stub data.
  # A host report is withheld if inventory or actual process-subtree cgroup
  # limits cannot be measured. The configured native VM path is not a hosted
  # container's current cgroup and MUST NOT substitute for /proc/self/cgroup.
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
  def sample(pools, _cgroup_path, previous, sequence, images, coverage, _native_io) do
    with true <- Pool.distinct?(pools),
         true <- Enum.all?(pools, &(&1.backend == :controlled)),
         {:ok, inventory} <- Inventory.read(),
         {:ok, path} <- self_cgroup_path("/sys/fs/cgroup", "/proc/self/cgroup"),
         {:ok, limits} <- measured_limits("/sys/fs/cgroup", "/proc/self/cgroup", inventory) do
      substrate = StubStorage.read()

      {capacity, usage, reported_pools, stub_images} =
        stub_sample(
          substrate,
          pools,
          "/sys/fs/cgroup",
          path,
          inventory,
          limits,
          previous,
          coverage
        )

      report = %{
        capacity: capacity,
        sequence: sequence,
        sampled_at: DateTime.utc_now(),
        effective_cores: limits.effective_cores,
        effective_memory_bytes: limits.effective_memory_bytes,
        inventory: %{
          "architecture" => inventory.architecture,
          "images" => Enum.sort(Enum.uniq(Image.available_ids(images) ++ stub_images)),
          "execution_ready" => false,
          "terminal_protocol" => 0,
          "inception_image_id" => nil
        },
        pools: reported_pools
      }

      {:ok, report, %{usage: usage}}
    else
      _ -> {:error, :collection_failed}
    end
  end

  # @cc [owner:ghuntley,label:capacity;verification] stub-capacity-measured-compute
  # Only a selected, valid stub substrate MAY replace unavailable pool entries,
  # and only with its configured stub totals. Memory headroom, the interval and
  # coverage MUST still come from Lilly's real usage sampler over this process's
  # measured cgroup subtree; an unknown interval MUST stay nil. CPU headroom is
  # the substrate's labelled STUB budget capped by the measured effective cores,
  # because the hosted single-CPU VM never measures a whole idle core. Without the stub, or with
  # an invalid one, every pool MUST stay unavailable and no image is added.
  @spec stub_sample(
          {:ok, StubStorage.t()} | :disabled | {:error, :stub_storage_invalid},
          [Pool.t()],
          Path.t(),
          Path.t(),
          Inventory.t(),
          Limits.t(),
          Lilly.Host.Collector.previous() | nil,
          map()
        ) :: {map() | nil, Usage.previous(), [OverallsProtocol.pool()], [String.t()]}
  def stub_sample({:ok, stub}, pools, root, path, inventory, limits, previous, coverage) do
    prior = if is_map(previous), do: Map.get(previous, :usage)
    {capacity, usage} = Usage.sample(root, path, inventory, limits, prior, coverage)
    capacity = stub_compute(capacity, stub, limits)

    {capacity, usage, Enum.map(pools, &StubStorage.pool_report(&1, stub)),
     StubStorage.image_ids(stub)}
  end

  def stub_sample(_substrate, pools, _root, _path, _inventory, _limits, _previous, _coverage),
    do: {nil, nil, Enum.map(pools, &%{id: &1.id, unavailable: true, storage: &1.storage}), []}

  @spec stub_compute(map() | nil, StubStorage.t(), Limits.t()) :: map() | nil
  defp stub_compute(capacity, stub, limits) when is_map(capacity) do
    budget = min(stub.stub_cpu_millicores, limits.effective_cores * 1000)
    Map.put(capacity, "cpu_headroom_millicores", budget)
  end

  defp stub_compute(capacity, _stub, _limits), do: capacity

  # @cc [owner:ghuntley,label:capacity;security] hosted-self-cgroup-measured
  # Hosted CPU and memory limits MUST be read from the one unified cgroup v2
  # entry for this process and every ancestor under the mounted root. Missing,
  # ambiguous, escaped or unreadable entries MUST withhold the whole report.
  @spec measured_limits(Path.t(), Path.t(), Inventory.t()) ::
          {:ok, Limits.t()} | {:error, :collection_failed}
  def measured_limits(root, proc_file, inventory) do
    with {:ok, path} <- self_cgroup_path(root, proc_file),
         {:ok, limits} <- Limits.read(root, path, inventory) do
      {:ok, limits}
    else
      _ -> {:error, :collection_failed}
    end
  end

  @spec self_cgroup_path(Path.t(), Path.t()) ::
          {:ok, Path.t()} | {:error, :collection_failed}
  def self_cgroup_path(root, proc_file) do
    with true <- Path.type(root) == :absolute and Path.expand(root) == root,
         {:ok, body} <- File.read(proc_file),
         true <- byte_size(body) in 1..4096 and String.valid?(body),
         ["0::/" <> relative] <- String.split(body, "\n", trim: true),
         true <- valid_relative?(relative) do
      {:ok, Path.join(root, relative)}
    else
      _ -> {:error, :collection_failed}
    end
  end

  @spec valid_relative?(String.t()) :: boolean()
  defp valid_relative?(""), do: true

  defp valid_relative?(relative) do
    not String.contains?(relative, [<<0>>, "\r", "\\"]) and
      Enum.all?(String.split(relative, "/"), &(&1 not in ["", ".", ".."]))
  end
end
