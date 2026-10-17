defmodule OverallsAntithesis.Lilly.Collector do
  @moduledoc "Hosted Control report with measured cgroup limits and explicitly unavailable storage."
  alias Lilly.Host.{Image, Inventory, Limits, Pool}

  # @cc [owner:ghuntley,label:capacity] hosted-capacity-never-fabricated
  # Synthetic pool identity cannot supply native capacity or physical headroom.
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
  def sample(pools, _cgroup_path, _previous, sequence, images, _coverage, _native_io) do
    with true <- Pool.distinct?(pools),
         true <- Enum.all?(pools, &(&1.backend == :controlled)),
         {:ok, inventory} <- Inventory.read(),
         {:ok, limits} <-
           measured_limits("/sys/fs/cgroup", "/proc/self/cgroup", inventory) do
      report = %{
        capacity: nil,
        sequence: sequence,
        sampled_at: DateTime.utc_now(),
        effective_cores: limits.effective_cores,
        effective_memory_bytes: limits.effective_memory_bytes,
        inventory: %{
          "architecture" => inventory.architecture,
          "images" => Image.available_ids(images),
          "execution_ready" => false,
          "terminal_protocol" => 0,
          "inception_image_id" => nil
        },
        pools: Enum.map(pools, &%{id: &1.id, unavailable: true, storage: &1.storage})
      }

      {:ok, report, %{usage: nil}}
    else
      _ -> {:error, :collection_failed}
    end
  end

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
  defp self_cgroup_path(root, proc_file) do
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
