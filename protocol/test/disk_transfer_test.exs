defmodule OverallsProtocol.DiskTransferTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.{CloneControl, DiskLayout, DiskTransfer, Relocation}

  defp id(n), do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

  defp intent do
    %{
      "version" => 3,
      "purpose" => "clone",
      "relocation_id" => id(1),
      "vm_id" => id(2),
      "destination_vm_id" => id(3),
      "source_slot" => 2,
      "source" => %{"host_id" => id(4), "pool_id" => id(5), "placement_id" => id(6)},
      "destination" => %{"host_id" => id(4), "pool_id" => id(5), "placement_id" => id(7)},
      "source_epoch" => 9,
      "destination_epoch" => 1,
      "workload" => %{
        "image_id" => "sha256:" <> String.duplicate("a", 64),
        "architecture" => "x86_64",
        "profile" => "customer",
        "slot" => 3,
        "vcpu" => 1,
        "memory_bytes" => 536_870_912,
        "disk_bytes" => 2_147_483_648
      }
    }
  end

  test "local clone has independent workload identity and is never relocation authority" do
    wire = intent()
    assert {:ok, parsed} = DiskTransfer.intent(wire)
    assert DiskTransfer.encode_intent(parsed) == wire
    assert DiskTransfer.source_workload(parsed).slot == 2
    assert parsed.workload.slot == 3
    assert {:error, _} = Relocation.intent(wire)

    for bad <- [
          Map.put(wire, "vm_id", wire["destination_vm_id"]),
          Map.put(wire, "source_slot", 3),
          Map.put(wire, "path", "/tmp/disk")
        ] do
      assert {:error, _} = DiskTransfer.intent(bad)
    end
  end

  test "multi-disk clone intents validate and keep the profile drive set on both endpoints" do
    wire = put_in(intent(), ["workload", "profile"], "inception")

    assert {:ok, parsed} = DiskTransfer.intent(wire)
    assert parsed.workload.profile == :inception
    assert DiskTransfer.encode_intent(parsed) == wire

    source = DiskTransfer.source_workload(parsed)

    assert [%{name: "rootfs.ext4", root: true}, %{name: "data.raw", root: false}] =
             DiskLayout.drives(source.profile, source.disk_bytes)

    assert DiskLayout.drives(source.profile, source.disk_bytes) ==
             DiskLayout.drives(parsed.workload.profile, parsed.workload.disk_bytes)
  end

  property "every profile's clone workload derives the full drive footprint" do
    check all(
            profile <- member_of([:customer, :standard, :oss, :inception]),
            disk <- member_of([2_147_483_648, 68_719_476_736, 536_870_912_000]),
            max_runs: 40
          ) do
      wire =
        intent()
        |> put_in(["workload", "profile"], Atom.to_string(profile))
        |> put_in(["workload", "disk_bytes"], disk)

      assert {:ok, parsed} = DiskTransfer.intent(wire)
      assert parsed.workload.profile == profile
      assert DiskLayout.bytes(profile, disk) >= disk
      assert Enum.all?(DiskLayout.drives(profile, disk), &(&1.bytes > 0))
    end
  end

  property "independent epochs and bounded sizes round trip without losing snapshot lineage" do
    check all(epoch <- integer(1..10000), cpu <- integer(1..32), max_runs: 60) do
      wire = intent() |> Map.put("source_epoch", epoch) |> put_in(["workload", "vcpu"], cpu)

      wire =
        Map.put(wire, "stream", %{"source_dataset_guid" => "12", "to_guid" => "14"})

      assert {:ok, parsed} = DiskTransfer.descriptor(wire)
      assert DiskTransfer.encode_descriptor(parsed) == wire

      for {field, value} <- [{"kind", "full"}, {"from_guid", nil}] do
        assert {:error, _} = DiskTransfer.descriptor(put_in(wire, ["stream", field], value))
      end
    end
  end

  test "effect envelope rejects wrong host, unknown fields and mixed intent" do
    wire = %{
      "id" => id(9),
      "clone_id" => id(1),
      "host_id" => id(4),
      "kind" => "capture",
      "endpoint" => "source",
      "intent" => intent(),
      "descriptor" => nil,
      "public_key" => nil,
      "source_endpoint" => nil,
      "source_generation" => 4,
      "revision" => 1,
      "expires_at" => 12345
    }

    assert {:ok, ^wire} = CloneControl.command(wire)
    assert {:error, _} = CloneControl.command(Map.put(wire, "host_id", id(10)))
    assert {:error, _} = CloneControl.command(Map.put(wire, "path", "/etc/passwd"))
    assert {:error, _} = CloneControl.command(Map.put(wire, "clone_id", id(11)))
  end
end
