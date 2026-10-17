defmodule OverallsProtocol.RelocationTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias OverallsProtocol.Relocation

  defp uuid(n), do: "00000000-0000-0000-0000-" <> String.pad_leading("#{n}", 12, "0")

  defp descriptor do
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
      },
      stream: %{source_dataset_guid: "100", to_guid: "200"}
    }
  end

  defp wire, do: Relocation.encode_descriptor(descriptor())

  property "arbitrary peer terms return a bounded validation result without raising" do
    check all(value <- term()) do
      assert Relocation.descriptor(value) in [
               {:error, :invalid_message},
               {:error, :unsupported_version}
             ]
    end
  end

  property "bounded epochs, shapes and snapshot GUIDs survive JSON without precision loss" do
    check all(
            epoch <- integer(1..9_223_372_036_854_775_806),
            guid <- integer(1..9_223_372_036_854_775_807),
            cpu <- integer(1..32),
            memory <- integer(512..262_144),
            disk <- integer(524_288..131_072_000)
          ) do
      value = descriptor()

      value = %{
        value
        | source_epoch: epoch,
          destination_epoch: epoch + 1,
          workload: %{
            value.workload
            | vcpu: cpu,
              memory_bytes: memory * 1_048_576,
              disk_bytes: disk * 4096
          },
          stream: %{value.stream | to_guid: to_string(guid)}
      }

      assert {:ok, ^value} =
               value
               |> Relocation.encode_descriptor()
               |> JSON.encode!()
               |> JSON.decode!()
               |> Relocation.descriptor()
    end
  end

  test "every object is closed and every field is required" do
    value = wire()

    for key <- Map.keys(value) do
      assert {:error, :invalid_message} = Relocation.descriptor(Map.delete(value, key))
    end

    for key <- ["source", "destination", "workload", "stream"] do
      for field <- Map.keys(value[key]) do
        assert {:error, :invalid_message} =
                 Relocation.descriptor(put_in(value, [key], Map.delete(value[key], field)))
      end

      assert {:error, :invalid_message} =
               Relocation.descriptor(put_in(value, [key, "extra"], "unexpected"))
    end

    for key <- ["path", "private_key", "command", "activate", "extra"] do
      assert {:error, :invalid_message} =
               Relocation.descriptor(Map.put(value, key, "unexpected"))
    end
  end

  test "different placement, host and pool are mandatory" do
    for key <- ["placement_id", "host_id", "pool_id"] do
      value = wire()

      assert {:error, :invalid_message} =
               Relocation.descriptor(put_in(value, ["destination", key], value["source"][key]))

      for endpoint <- ["source", "destination"], invalid <- [nil, "../disk", uuid(1) <> "\n"] do
        assert {:error, :invalid_message} =
                 Relocation.descriptor(put_in(value, [endpoint, key], invalid))
      end
    end
  end

  test "epochs cannot stay equal, skip, regress, overflow or use imprecise numbers" do
    for {source, destination} <- [
          {0, 1},
          {-1, 0},
          {1, 1},
          {2, 1},
          {1, 3},
          {1.0, 2},
          {1, 2.0},
          {nil, 2},
          {9_223_372_036_854_775_807, 9_223_372_036_854_775_807}
        ] do
      assert {:error, :invalid_message} =
               Relocation.descriptor(%{
                 wire()
                 | "source_epoch" => source,
                   "destination_epoch" => destination
               })
    end
  end

  test "source filesystem identity cannot be confused with destination ownership" do
    value = wire()
    stream = value["stream"]

    for field <- ["dataset_guid", "destination_dataset_guid"] do
      ambiguous =
        stream
        |> Map.delete("source_dataset_guid")
        |> Map.put(field, stream["source_dataset_guid"])

      assert {:error, :invalid_message} =
               Relocation.descriptor(%{value | "stream" => ambiguous})

      assert {:error, :invalid_message} =
               Relocation.descriptor(put_in(value, ["stream", field], "300"))
    end
  end

  test "streams reject missing, noncanonical and overflowing GUIDs" do
    for field <- ["source_dataset_guid", "to_guid"],
        invalid <- [nil, "0", "01", "-1", "1\n", "18446744073709551616", 1] do
      assert {:error, :invalid_message} =
               Relocation.descriptor(put_in(wire(), ["stream", field], invalid))
    end
  end

  test "removed incremental lineage fields are rejected, not ignored" do
    for {field, value} <- [
          {"kind", "full"},
          {"kind", "incremental"},
          {"kind", "baseline"},
          {"from_guid", nil},
          {"from_guid", "150"}
        ] do
      assert {:error, :invalid_message} =
               Relocation.descriptor(put_in(wire(), ["stream", field], value))
    end
  end

  test "unsupported versions and malformed top-level values fail closed" do
    for version <- [1, 2, 4, "3", nil] do
      assert {:error, :unsupported_version} =
               Relocation.descriptor(%{wire() | "version" => version})
    end

    for value <- [nil, [], 3, "descriptor", %{}] do
      assert {:error, :invalid_message} = Relocation.descriptor(value)
    end
  end

  test "immutable workload identity and execution limits cannot be weakened by relocation" do
    for {key, value} <- [
          {"image_id", "latest"},
          {"architecture", "aarch64"},
          {"profile", "arbitrary_peer_atom"},
          {"slot", 1},
          {"slot", 65535},
          {"vcpu", 0},
          {"vcpu", 33},
          {"memory_bytes", 536_870_913},
          {"disk_bytes", 2_147_483_649}
        ] do
      assert {:error, :invalid_message} =
               Relocation.descriptor(put_in(wire(), ["workload", key], value))
    end
  end
end
