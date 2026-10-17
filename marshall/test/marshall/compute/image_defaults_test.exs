defmodule Marshall.Compute.ImageDefaultsTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  property "defaults round upward to input units and satisfy every executable image minimum" do
    check all(
            memory <- integer(536_870_912..274_877_906_944),
            disk <- integer(1..536_870_912_000)
          ) do
      shape =
        Marshall.Compute.Image.default_shape(%{
          minimum_memory_bytes: memory,
          minimum_disk_bytes: disk
        })

      assert OverallsProtocol.VMShape.valid?(shape.vcpu, shape.memory_bytes, shape.disk_bytes)
      assert shape.memory_bytes >= memory
      assert shape.disk_bytes >= disk
      assert shape.memory_bytes - max(memory, 536_870_912) < 1_048_576
      assert shape.disk_bytes - max(disk, 2_147_483_648) < 1_073_741_824
    end
  end
end
