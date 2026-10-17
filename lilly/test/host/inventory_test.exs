defmodule Lilly.Host.InventoryTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Lilly.Host.Inventory

  test "hyperthreads do not inflate physical core or socket counts" do
    cpuinfo = Enum.map_join(0..7, "\n\n", &cpu(&1, div(&1, 4), div(rem(&1, 4), 2)))
    assert {:ok, inventory} = Inventory.parse_cpu(cpuinfo)
    assert inventory.logical_cores == 8
    assert inventory.physical_cores == 4
    assert inventory.sockets == 2
    assert inventory.cpu_model == "Example CPU"
  end

  test "missing physical topology is reported as unknown" do
    assert {:ok, inventory} = Inventory.parse_cpu("processor: 0\nmodel name: Example CPU\n")
    assert inventory.logical_cores == 1
    assert inventory.physical_cores == nil
    assert inventory.sockets == nil
  end

  test "missing, malformed and duplicate processor IDs fail collection" do
    for input <- ["", "processor: invalid", "processor: 0\n\nprocessor: 0"] do
      assert {:error, :invalid_cpu_inventory} = Inventory.parse_cpu(input)
    end
  end

  test "memory units are bytes and used excludes reclaimable memory" do
    assert {:ok, memory} = Inventory.parse_memory(meminfo(1000, 200, 600))
    assert memory.total_bytes == 1_024_000
    assert memory.free_bytes == 204_800
    assert memory.available_bytes == 614_400
    assert memory.used_bytes == 409_600
    assert memory.utilization_percent == 40.0
  end

  test "missing or impossible memory observations do not become free capacity" do
    for input <- [
          "",
          meminfo(0, 0, 0),
          meminfo(100, 101, 101),
          meminfo(100, 20, 101),
          String.replace(meminfo(100, 20, 50), "kB", "MB")
        ] do
      assert {:error, :invalid_memory_inventory} = Inventory.parse_memory(input)
    end
  end

  test "available memory can be below free memory because of kernel watermarks" do
    assert {:ok, memory} = Inventory.parse_memory(meminfo(100, 80, 60))
    assert memory.free_bytes == 80 * 1024
    assert memory.available_bytes == 60 * 1024
  end

  test "read reports unavailable procfs without fabricating inventory" do
    root = Path.join(System.tmp_dir!(), "missing-procfs-#{System.unique_integer([:positive])}")
    assert {:error, :enoent} = Inventory.read(root)
  end

  property "logical CPUs scale with threading while physical cores stay fixed" do
    check all(sockets <- integer(1..4), cores <- integer(1..16), threads <- integer(1..4)) do
      records =
        for socket <- 0..(sockets - 1), core <- 0..(cores - 1), thread <- 0..(threads - 1) do
          cpu((socket * cores + core) * threads + thread, socket, core)
        end

      assert {:ok, inventory} = Inventory.parse_cpu(Enum.join(Enum.reverse(records), "\n\n"))
      assert inventory.logical_cores == sockets * cores * threads
      assert inventory.physical_cores == sockets * cores
      assert inventory.sockets == sockets
    end
  end

  property "valid memory observations conserve capacity and produce bounded percentages" do
    check all(
            total <- integer(1..1_000_000),
            available <- integer(0..total),
            free <- integer(0..total)
          ) do
      assert {:ok, memory} = Inventory.parse_memory(meminfo(total, free, available))
      assert memory.used_bytes + memory.available_bytes == memory.total_bytes
      assert memory.free_bytes <= memory.total_bytes
      assert memory.utilization_percent >= 0.0
      assert memory.utilization_percent <= 100.0
    end
  end

  defp cpu(processor, socket, core) do
    "processor: #{processor}\nphysical id: #{socket}\ncore id: #{core}\nmodel name: Example CPU"
  end

  defp meminfo(total, free, available) do
    "MemTotal: #{total} kB\nMemFree: #{free} kB\nMemAvailable: #{available} kB\n"
  end
end
