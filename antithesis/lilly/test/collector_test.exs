defmodule OverallsAntithesis.Lilly.CollectorTest do
  use ExUnit.Case, async: true

  alias OverallsAntithesis.Lilly.Collector
  alias Lilly.Host.Inventory

  @moduletag :tmp_dir

  test "measures the process leaf and every enabled ancestor", %{tmp_dir: root} do
    cgroup_root = Path.join(root, "cgroup")
    File.mkdir!(cgroup_root)
    File.write!(Path.join(cgroup_root, "cgroup.controllers"), "cpu memory cpuset\n")
    File.write!(Path.join(cgroup_root, "cgroup.subtree_control"), "cpu memory cpuset\n")
    File.write!(Path.join(cgroup_root, "cpuset.cpus.effective"), "0-7\n")

    parent = group(cgroup_root, "user.slice", "200000 100000", "4294967296", "0-3")
    leaf = group(parent, "container", "100000 100000", "2147483648", "0-1")
    proc_file = Path.join(root, "self-cgroup")
    File.write!(proc_file, "0::/user.slice/container\n")

    assert {:ok, limits} = Collector.measured_limits(cgroup_root, proc_file, inventory())
    assert limits.cgroup_path == leaf
    assert limits.effective_cores == 1
    assert limits.effective_memory_bytes == 2_147_483_648

    File.write!(Path.join(parent, "cgroup.subtree_control"), "cpu memory\n")
    File.rm!(Path.join(leaf, "cpuset.cpus.effective"))

    assert {:ok, %{effective_cores: 1, effective_memory_bytes: 2_147_483_648}} =
             Collector.measured_limits(cgroup_root, proc_file, inventory())

    File.write!(proc_file, "0::/user.slice/../container\n")

    assert {:error, :collection_failed} =
             Collector.measured_limits(cgroup_root, proc_file, inventory())

    File.write!(proc_file, "0::/user.slice/container\n0::/other\n")

    assert {:error, :collection_failed} =
             Collector.measured_limits(cgroup_root, proc_file, inventory())

    File.write!(proc_file, "0::/user.slice/container\n")
    File.rm!(Path.join(leaf, "memory.max"))

    assert {:error, :collection_failed} =
             Collector.measured_limits(cgroup_root, proc_file, inventory())
  end

  @spec group(Path.t(), String.t(), String.t(), String.t(), String.t()) :: Path.t()
  defp group(parent, name, cpu, memory, cpuset) do
    path = Path.join(parent, name)
    File.mkdir!(path)

    for {file, content} <- [
          {"cgroup.type", "domain"},
          {"cgroup.subtree_control", "cpu memory cpuset"},
          {"cpu.max", cpu},
          {"memory.max", memory},
          {"cpuset.cpus.effective", cpuset}
        ],
        do: File.write!(Path.join(path, file), content)

    path
  end

  @spec inventory() :: Inventory.t()
  defp inventory do
    %Inventory{
      architecture: "x86_64",
      logical_cores: 8,
      memory: %{
        total_bytes: 8_589_934_592,
        free_bytes: 0,
        available_bytes: 0,
        used_bytes: 8_589_934_592,
        utilization_percent: 100.0
      }
    }
  end
end
