defmodule Lilly.Host.UsageTest do
  use ExUnit.Case, async: true
  alias Lilly.Host.{Inventory, Usage}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.write!(Path.join(root, "cpu.stat"), "usage_usec 0\n")
    File.write!(Path.join(root, "cgroup.subtree_control"), "cpu memory cpuset")
    parent = group(root, "parent", "400000 100000", "8000", "2000")
    leaf = group(parent, "guests", "600000 100000", "7000", "1000")

    inventory = %Inventory{
      architecture: "x86_64",
      logical_cores: 8,
      memory: %{available_bytes: 5000}
    }

    limits = %{effective_cores: 4, effective_memory_bytes: 7000}
    %{root: root, leaf: leaf, parent: parent, inventory: inventory, limits: limits}
  end

  test "first sample is unknown; ancestor CPU and host memory constrain headroom", c do
    assert {nil, previous} = sample(c, nil)
    previous = %{previous | at: System.monotonic_time(:microsecond) - 1_000_000}
    File.write!(Path.join(c.parent, "cpu.stat"), "usage_usec 2000000\n")
    {usage, _} = sample(c, previous)
    # Two CPU-seconds consumed under the four-core ancestor limit. Use the
    # observed interval: scheduler delays must not change the capacity oracle.
    assert usage["cpu_headroom_millicores"] ==
             4000 - ceil(2_000_000_000 / usage["interval_us"])

    assert usage["memory_headroom_bytes"] == 5000
    File.write!(Path.join(c.parent, "memory.current"), "7900")
    {usage, _} = sample(c, previous)
    assert usage["memory_headroom_bytes"] == 100
  end

  test "counter reset, missing data and long intervals remain unknown", c do
    {nil, previous} = sample(c, nil)
    assert {nil, _} = sample(c, %{previous | at: System.monotonic_time(:microsecond) - 6_000_000})
    prior = put_in(previous.scopes[c.leaf].usage, 100)
    assert {nil, _} = sample(c, prior)
    File.rm!(Path.join(c.parent, "memory.current"))
    assert {nil, nil} = sample(c, previous)
  end

  test "coverage must be identical at both boundaries and full pressure is known zero", c do
    proof = %{"generation" => 1}
    {nil, previous} = sample(c, nil, %{"a" => proof})
    File.write!(Path.join(c.leaf, "memory.current"), "7001")
    File.write!(Path.join(c.root, "cpu.stat"), "usage_usec 100000000\n")
    {usage, _} = sample(c, previous, %{"a" => proof, "b" => proof})
    assert usage["covered"] == %{"a" => proof}
    assert usage["cpu_headroom_millicores"] == 0
    assert usage["memory_headroom_bytes"] == 0
    {usage, _} = sample(c, previous, %{"a" => %{"generation" => 2}})
    assert usage["covered"] == %{}
  end

  defp sample(c, previous, coverage \\ %{}),
    do: Usage.sample(c.root, c.leaf, c.inventory, c.limits, previous, coverage)

  defp group(parent, name, cpu, maximum, used) do
    path = Path.join(parent, name)
    File.mkdir!(path)

    for {file, value} <- [
          {"cpu.stat", "usage_usec 0\n"},
          {"cpu.max", cpu},
          {"memory.max", maximum},
          {"memory.current", used},
          {"cpuset.cpus.effective", "0-7"},
          {"cgroup.subtree_control", "cpu memory cpuset"}
        ],
        do: File.write!(Path.join(path, file), value)

    path
  end
end
