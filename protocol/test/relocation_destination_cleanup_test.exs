defmodule OverallsProtocol.RelocationDestinationCleanupTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.RelocationDestinationCleanup, as: Wire
  defp uuid(n), do: "00000000-0000-0000-0000-" <> String.pad_leading("#{n}", 12, "0")

  defp intent do
    %{
      relocation_id: uuid(1),
      vm_id: uuid(2),
      source: %{placement_id: uuid(3), host_id: uuid(4), pool_id: uuid(5)},
      destination: %{placement_id: uuid(6), host_id: uuid(7), pool_id: uuid(8)},
      source_epoch: 1,
      destination_epoch: 2,
      workload: %{
        image_id: "sha256:" <> String.duplicate("a", 64),
        architecture: :x86_64,
        profile: :customer,
        slot: 2,
        vcpu: 1,
        memory_bytes: 536_870_912,
        disk_bytes: 2_147_483_648
      }
    }
  end

  test "cleanup has immutable intent but no invented stream lineage" do
    command = %{id: uuid(1), intent: intent(), expires_at: 180}
    encoded = Wire.encode(command)
    assert {:ok, ^command} = Wire.command(encoded)
    assert {:ok, [^command]} = Wire.commands([encoded])

    for invalid <- [
          Map.put(encoded, "id", uuid(99)),
          Map.put(encoded, "dataset_guid", "1"),
          put_in(encoded, ["intent", "stream"], %{}),
          put_in(encoded, ["intent", "destination_epoch"], 1),
          Map.put(encoded, "expires_at", 0),
          Map.put(encoded, "expires_at", "180")
        ] do
      assert {:error, :invalid_message} = Wire.command(invalid)
    end

    assert {:error, :invalid_message} = Wire.commands([encoded, encoded])
    assert {:error, :invalid_message} = Wire.commands(List.duplicate(encoded, 17))
  end

  test "receipts and envelopes remain closed, bounded and versioned" do
    result = %{id: uuid(1), placement_id: uuid(6), execution_epoch: 2}
    encoded = Wire.encode(result)
    assert {:ok, ^result} = Wire.result(encoded)
    message = %{"version" => 4, "session_id" => uuid(9), "epoch" => 1, "results" => [encoded]}
    assert {:ok, _} = Wire.exchange(message)
    assert {:error, :unsupported_version} = Wire.exchange(%{message | "version" => 2})

    assert {:error, :invalid_message} =
             Wire.exchange(%{message | "results" => [encoded, encoded]})

    assert {:error, :invalid_message} = Wire.result(Map.put(encoded, "source_restored", true))
    assert {:error, :invalid_message} = Wire.result(%{encoded | "execution_epoch" => 1})
  end
end
