defmodule Lilly.Host.LimitsTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{Inventory, Limits}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.write!(Path.join(root, "cgroup.controllers"), "cpu memory cpuset\n")
    File.write!(Path.join(root, "cgroup.subtree_control"), "cpu memory cpuset\n")
    File.write!(Path.join(root, "cpuset.cpus.effective"), "0-7\n")

    inventory = %Inventory{
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

    %{root: root, inventory: inventory}
  end

  test "every ancestor constrains the VM subtree and fractional quotas round down", %{
    root: root,
    inventory: inventory
  } do
    parent = group(root, "parent", "150000 100000", "4294967296", "0-5")
    leaf = group(parent, "guests", "300000 100000", "max", "0-3")
    assert {:ok, limits} = Limits.read(root, leaf, inventory)
    assert limits.effective_cores == 1
    assert limits.cpu_quota_cores == 1.5
    assert limits.effective_memory_bytes == 4_294_967_296
    assert limits.cpuset_cores == 4
    File.write!(Path.join(leaf, "cpu.max"), "50000 100000")
    assert {:ok, %{effective_cores: 0}} = Limits.read(root, leaf, inventory)
  end

  test "missing enabled controller files and threaded/escaped paths fail closed", %{
    root: root,
    inventory: inventory
  } do
    leaf = group(root, "guests", "max 100000", "max", "0-7")
    File.rm!(Path.join(leaf, "memory.max"))
    assert {:error, :invalid_cgroup_limits} = Limits.read(root, leaf, inventory)
    File.write!(Path.join(leaf, "memory.max"), "max")
    File.write!(Path.join(leaf, "cgroup.type"), "threaded")
    assert {:error, :invalid_cgroup_limits} = Limits.read(root, leaf, inventory)
    assert {:error, :invalid_cgroup_limits} = Limits.read(root, root <> "-escape", inventory)
  end

  @tag :hegel

  test "quota capacity uses integer division even beyond floating point precision", %{
    root: root,
    inventory: inventory
  } do
    leaf = group(root, "guests", "max 100000", "max", "0-7")

    check all(period <- integer(1..1_000_000_000_000_000_000), cores <- integer(1..8)) do
      quota = cores * period - 1
      File.write!(Path.join(leaf, "cpu.max"), "#{quota} #{period}")
      assert {:ok, limits} = Limits.read(root, leaf, inventory)
      assert limits.effective_cores == cores - 1
    end
  end

  property "CPU ranges count distinct processors without expanding large lists" do
    check all(a <- integer(0..10000), length <- integer(1..10000), gap <- integer(1..100)) do
      assert {:ok, count} = Limits.cpuset_count("#{a}-#{a + length - 1},#{a + length + gap}")
      assert count == length + 1
      assert :error = Limits.cpuset_count("#{a}-#{a + length - 1},#{a}")
    end
  end

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
end
