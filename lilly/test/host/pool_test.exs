defmodule Lilly.Host.PoolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Lilly.Host.Pool

  property "ZFS siblings and backing extent overlaps cannot duplicate capacity" do
    check all(start <- integer(0..10000), size <- integer(1..10000)) do
      extent = %{backing_device: "8:0", start_sector: start, sectors: size}

      zfs = %{
        filesystem_id: "zfs:1:2",
        storage: %{backend: :zfs, zpool_guid: "1"},
        extents: [extent]
      }

      sibling = %{zfs | filesystem_id: "zfs:1:3", extents: [%{extent | backing_device: "8:16"}]}
      refute Pool.distinct?([zfs, sibling])
      other = %{zfs | filesystem_id: "zfs:3:4", storage: %{backend: :zfs, zpool_guid: "3"}}
      refute Pool.distinct?([zfs, other])
      assert Pool.distinct?([zfs, %{other | extents: [%{extent | start_sector: start + size}]}])
      refute Pool.distinct?([zfs, zfs])
    end
  end

  @tag :tmp_dir
  test "partition extents resolve their parent, while stacked and loop devices fail", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "dev/block"))
    disk = Path.join(root, "devices/disk")
    File.mkdir_p!(Path.join(disk, "slaves"))
    File.write!(Path.join(disk, "dev"), "8:0")
    File.write!(Path.join(disk, "size"), "1000")
    File.ln_s!(disk, Path.join(root, "dev/block/8:0"))

    assert {:ok, %{backing_device: "8:0", start_sector: 0, sectors: 1000}} =
             Pool.device_extent(root, "8:0")

    partition = Path.join(disk, "partition1")
    File.mkdir!(partition)

    for {file, value} <- [{"partition", "1"}, {"start", "100"}, {"size", "500"}],
        do: File.write!(Path.join(partition, file), value)

    File.ln_s!(partition, Path.join(root, "dev/block/8:1"))

    assert {:ok, %{backing_device: "8:0", start_sector: 100, sectors: 500}} =
             Pool.device_extent(root, "8:1")

    File.mkdir!(Path.join(disk, "dm"))
    assert :error = Pool.device_extent(root, "8:0")
    assert :error = Pool.device_extent(root, "8:1")
    File.rmdir!(Path.join(disk, "dm"))
    File.mkdir!(Path.join(disk, "loop"))
    assert :error = Pool.device_extent(root, "8:0")
    File.rmdir!(Path.join(disk, "loop"))
    File.write!(Path.join(disk, "slaves/shared"), "")
    assert :error = Pool.device_extent(root, "8:0")
  end

  test "native ZFS backing validation accepts disjoint devices without filesystem descriptors" do
    a = %{backing_device: "8:0", start_sector: 0, sectors: 100}
    b = %{backing_device: "8:16", start_sector: 0, sectors: 100}
    assert Pool.distinct_extents?([a, b])
    assert Pool.distinct_extents?([a, %{a | start_sector: 100}])
    refute Pool.distinct_extents?([a, a])
    refute Pool.distinct_extents?([a, %{a | start_sector: 99}])
  end
end
