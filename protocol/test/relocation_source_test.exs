defmodule OverallsProtocol.RelocationSourceTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.RelocationSource, as: Codec
  alias OverallsProtocol.Relocation
  defp id(n), do: "00000000-0000-4000-8000-" <> String.pad_leading(to_string(n), 12, "0")

  defp command do
    %{
      id: id(1),
      generation: 1,
      revision: 1,
      expires_at: 1_900_000_000,
      public_key: "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 0::256>>),
      to_guid: nil,
      intent: %{
        relocation_id: id(2),
        vm_id: id(3),
        source_epoch: 1,
        destination_epoch: 2,
        source: %{placement_id: id(4), host_id: id(5), pool_id: id(6)},
        destination: %{placement_id: id(7), host_id: id(8), pool_id: id(9)},
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
    }
  end

  defp result(c),
    do: %{
      id: c.id,
      descriptor: Map.put(c.intent, :stream, %{source_dataset_guid: "100", to_guid: "200"})
    }

  property "arbitrary peer terms cannot raise or become source authority" do
    check all(value <- term()) do
      assert Codec.command(value) == {:error, :invalid_message}

      assert Relocation.intent(value) in [
               {:error, :invalid_message},
               {:error, :unsupported_version}
             ]
    end
  end

  test "intent does not fabricate snapshot GUIDs and source results bind every request field" do
    for to_guid <- [nil, "200"] do
      c = %{command() | to_guid: to_guid}

      assert {:ok, ^c} =
               c |> Codec.encode_command() |> JSON.encode!() |> JSON.decode!() |> Codec.command()

      r = result(c)

      assert {:ok, ^r} =
               r |> Codec.encode_result() |> JSON.encode!() |> JSON.decode!() |> Codec.result()

      assert Codec.matches?(c, r)
      refute Codec.matches?(%{c | id: id(20)}, r)
      refute Codec.matches?(%{c | to_guid: "999"}, r)
      refute Codec.matches?(put_in(c.intent.destination_epoch, 3), r)
      assert {:error, _} = Relocation.descriptor(Relocation.encode_intent(c.intent))
    end
  end

  test "closed fields, lineage, version and batch bounds reject whole messages" do
    wire = Codec.encode_command(command())

    for key <- ~w(path argv private_key unknown) do
      assert {:error, _} = Codec.command(Map.put(wire, key, "foreign"))
    end

    for key <- ~w(generation revision expires_at),
        bad <- [0, -1, 1.5, 9_223_372_036_854_775_807] do
      assert {:error, _} = Codec.command(Map.put(wire, key, bad))
    end

    # ADR-0155 removed stream kinds and parent GUIDs; they are foreign fields now.
    for {key, value} <- [{"kind", "full"}, {"kind", "incremental"}, {"from_guid", nil}] do
      assert {:error, _} = Codec.command(Map.put(wire, key, value))
    end

    assert {:error, _} = Codec.command(Map.put(wire, "to_guid", "01"))
    assert {:error, _} = Codec.command(Map.put(wire, "public_key", "private material"))
    assert {:error, _} = Codec.commands([wire, wire])
    assert {:ok, _} = Codec.commands(for n <- 1..16, do: Map.put(wire, "id", id(n)))
    assert {:error, _} = Codec.commands(for n <- 1..17, do: Map.put(wire, "id", id(n)))
    message = %{"version" => 4, "session_id" => id(2), "epoch" => 1, "results" => []}
    assert {:ok, _} = Codec.exchange(message)
    assert {:error, :unsupported_version} = Codec.exchange(Map.put(message, "version", 2))
    assert {:error, _} = Codec.exchange(Map.put(message, "path", "/tmp/foreign"))
  end
end
