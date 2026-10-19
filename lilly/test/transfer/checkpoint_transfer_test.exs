defmodule Lilly.Transfer.CheckpointTransferTest do
  use ExUnit.Case, async: true
  alias Lilly.Transfer.CheckpointTransfer

  @spec id(pos_integer()) :: String.t()
  defp id(n), do: "00000000-0000-0000-0000-" <> String.pad_leading(to_string(n), 12, "0")

  @spec workload() :: map()
  defp workload do
    %{
      "image_id" => "sha256:" <> String.duplicate("a", 64),
      "architecture" => "x86_64",
      "profile" => "customer",
      "slot" => 3,
      "vcpu" => 1,
      "memory_bytes" => 536_870_912,
      "disk_bytes" => 2_147_483_648
    }
  end

  test "a cross-host clone descriptor pulls no RAM and needs no checkpoint authority" do
    clone = %{
      "version" => 3,
      "purpose" => "clone",
      "relocation_id" => id(1),
      "vm_id" => id(2),
      "destination_vm_id" => id(3),
      "source_slot" => 2,
      "source" => %{"host_id" => id(4), "pool_id" => id(5), "placement_id" => id(6)},
      "destination" => %{"host_id" => id(8), "pool_id" => id(9), "placement_id" => id(7)},
      "source_epoch" => 9,
      "destination_epoch" => 1,
      "workload" => workload(),
      "stream" => %{"source_dataset_guid" => "100", "to_guid" => "200"}
    }

    assert {:ok, _} = OverallsProtocol.DiskTransfer.descriptor(clone)
    # No pool, endpoint or key is touched: a clone has nothing to pull here.
    assert :ok = CheckpointTransfer.pull("/nonexistent", nil, clone, %{}, 60_000, 1, nil)
  end

  test "malformed wires stay unconfirmed" do
    assert {:error, :checkpoint_unconfirmed} =
             CheckpointTransfer.pull("/nonexistent", nil, %{"version" => 3}, %{}, 60_000, 1, nil)
  end
end
