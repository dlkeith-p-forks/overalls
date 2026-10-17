defmodule LillyHostOwnershipBehaviorContractTest do
  use Covenant.Case, component: "lilly.host_ownership"

  @tag obligation: "lilly.host_ownership.I2"
  test "inventory parsing conserves memory and rejects malformed input" do
    text = "MemTotal:       1024 kB\nMemFree:         256 kB\nMemAvailable:    768 kB\n"
    assert {:ok, memory} = Lilly.Host.Inventory.parse_memory(text)
    assert memory.total_bytes == 1_048_576
    assert memory.used_bytes == memory.total_bytes - memory.available_bytes

    assert {:error, :invalid_memory_inventory} =
             Lilly.Host.Inventory.parse_memory("MemTotal: 1 kB\n")
  end

  @tag obligation: "lilly.host_ownership.I3"
  test "cpu topology remains unknown when fields are absent" do
    assert {:ok, cpu} = Lilly.Host.Inventory.parse_cpu("processor: 0\nmodel name: test\n")
    assert cpu.logical_cores == 1
    assert is_nil(cpu.physical_cores)

    assert {:error, :invalid_cpu_inventory} =
             Lilly.Host.Inventory.parse_cpu("processor: 0\n\nprocessor: 0\n")
  end
end
