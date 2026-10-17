defmodule OverallsProtocol.DiskLayoutTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.{DiskLayout, VMShape}

  test "Inception reserves both disks without inflating the root size or other profiles" do
    shape = %{
      profile: :inception,
      disk_bytes: 64 * 1024 ** 3,
      memory_bytes: 32 * 1024 ** 3,
      vcpu: 16
    }

    assert VMShape.reservation(shape).disk_bytes ==
             320 * 1024 ** 3 + OverallsProtocol.WorkloadBundle.storage_bytes()

    assert [
             %{name: "rootfs.ext4", bytes: root_bytes, root: true},
             %{name: "data.raw", bytes: data_bytes, root: false}
           ] = DiskLayout.drives(:inception, shape.disk_bytes)

    assert root_bytes == shape.disk_bytes
    assert data_bytes == 256 * 1024 ** 3

    for profile <- [:customer, :standard, :oss] do
      assert [%{name: "rootfs.ext4", bytes: ^root_bytes, root: true}] =
               DiskLayout.drives(profile, root_bytes)

      assert VMShape.reservation(%{shape | profile: profile}).disk_bytes ==
               root_bytes + OverallsProtocol.WorkloadBundle.storage_bytes()
    end

    assert VMShape.reservation(Map.delete(shape, :profile)).disk_bytes ==
             root_bytes + OverallsProtocol.WorkloadBundle.storage_bytes()
  end

  test "root growth never resizes the Inception data disk" do
    [_, before] = DiskLayout.drives(:inception, 64 * 1024 ** 3)
    [_, after_growth] = DiskLayout.drives(:inception, 128 * 1024 ** 3)
    assert before == after_growth
    assert DiskLayout.bytes(:inception, 128 * 1024 ** 3) == 384 * 1024 ** 3
  end
end
