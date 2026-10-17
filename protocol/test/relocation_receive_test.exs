defmodule OverallsProtocol.RelocationReceiveTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  alias OverallsProtocol.RelocationReceive, as: Codec

  defp id(n) do
    "00000000-0000-4000-8000-" <> String.pad_leading(to_string(n), 12, "0")
  end

  defp source do
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

  defp command do
    s = source()

    %{
      id: s.id,
      expires_at: s.expires_at,
      source_endpoint: %{
        "address" => "source.example",
        "port" => 2222,
        "host_key" => s.public_key
      },
      descriptor: Map.put(s.intent, :stream, %{source_dataset_guid: "100", to_guid: "200"})
    }
  end

  test "adoption accepts only full-stream descriptors with a local GUID and closed lease fields" do
    alias OverallsProtocol.RelocationImport

    import = Map.put(command(), :dataset_guid, "300")
    wire = RelocationImport.encode_command(import)
    assert {:ok, ^import} = RelocationImport.command(wire)
    assert {:error, _} = RelocationImport.command(Map.put(wire, "dataset_guid", "0300"))
    assert {:error, _} = RelocationImport.command(Map.put(wire, "extra", true))
    assert {:error, _} = RelocationImport.commands([wire, wire])

    assert {:error, _} =
             RelocationImport.command(put_in(wire["descriptor"]["stream"]["kind"], "incremental"))

    result = Map.take(import, [:id, :descriptor, :dataset_guid])
    assert {:ok, ^result} = RelocationImport.result(RelocationImport.encode_result(result))
    assert {:error, :unsupported_version} = RelocationImport.exchange(%{"version" => 2})

    assert {:ok, %{results: [^result]}} =
             RelocationImport.exchange(%{
               "version" => 4,
               "session_id" => id(1),
               "epoch" => 1,
               "results" => [RelocationImport.encode_result(result)]
             })
  end

  test "guest readiness wire binds activation generation and rejects lineage or forged boot data" do
    alias OverallsProtocol.RelocationReadiness
    receive = command()

    ready = %{
      id: receive.id,
      descriptor: receive.descriptor,
      generation: 3,
      expires_at: receive.expires_at,
      timeout_ms: 120_000
    }

    wire = RelocationReadiness.encode_command(ready)
    assert {:ok, ^ready} = RelocationReadiness.command(wire)

    for timeout <- [0, -1, 600_001, "120000"] do
      assert({:error, _} = RelocationReadiness.command(Map.put(wire, "timeout_ms", timeout)))
    end

    assert {:error, _} = RelocationReadiness.command(Map.put(wire, "path", "/v.sock"))

    assert {:error, _} =
             RelocationReadiness.command(put_in(wire["descriptor"]["stream"]["kind"], "full"))

    receipt = %{id: ready.id, descriptor: ready.descriptor, generation: 3, boot_id: id(10)}

    assert {:ok, ^receipt} =
             receipt |> RelocationReadiness.encode_result() |> RelocationReadiness.result()

    assert {:error, _} =
             RelocationReadiness.result(
               Map.put(RelocationReadiness.encode_result(receipt), "boot_id", "bad")
             )

    assert {:error, _} = RelocationReadiness.commands([wire, wire])
    assert {:error, :unsupported_version} = RelocationReadiness.exchange(%{"version" => 2})
  end

  test "source cleanup binds final lineage and refuses spare fields and exhausted generation" do
    alias OverallsProtocol.RelocationCleanup, as: Cleanup
    d = command().descriptor
    command = %{id: d.relocation_id, descriptor: d, generation: 2, expires_at: 1_900_000_000}
    wire = Cleanup.encode_command(command)
    assert {:ok, ^command} = Cleanup.command(wire)
    result = Map.drop(command, [:expires_at])
    assert {:ok, ^result} = Cleanup.result(Cleanup.encode_result(result))

    for changed <- [
          Map.put(wire, "id", id(99)),
          Map.put(wire, "path", "/pool"),
          Map.put(wire, "generation", 9_223_372_036_854_775_807),
          put_in(wire["descriptor"]["stream"]["kind"], "full")
        ] do
      assert {:error, _} = Cleanup.command(changed)
    end

    assert {:error, _} = Cleanup.commands([wire, wire])

    assert {:error, _} =
             Cleanup.result(Map.put(Cleanup.encode_result(result), "disk_present", true))

    assert {:error, :unsupported_version} = Cleanup.exchange(%{"version" => 2})

    assert {:ok, _} =
             Cleanup.exchange(%{
               "version" => 4,
               "session_id" => id(99),
               "epoch" => 9_223_372_036_854_775_807,
               "results" => []
             })
  end

  test "receive exchange rejects retired diagnostic progress" do
    message = %{"version" => 4, "session_id" => id(2), "epoch" => 1, "results" => []}
    assert {:ok, %{results: []}} = Codec.exchange(message)

    for progress <- [[], nil, [%{"bytes" => 12}]] do
      assert {:error, :invalid_message} = Codec.exchange(Map.put(message, "progress", progress))
    end

    assert {:error, :unsupported_version} = Codec.exchange(%{message | "version" => 3})
  end

  property "arbitrary terms cannot become receive commands or receipts",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_281_258_641 do
    value = draw("value", OverallsProtocol.TestGenerators.peer_term())
    assert Codec.command(value) == {:error, :invalid_message}
    assert Codec.result(value) == {:error, :invalid_message}
  end

  test "streams retain exact endpoints, pin, expiry and local GUID through JSON" do
    c = command()

    assert {:ok, ^c} =
             c |> Codec.encode_command() |> JSON.encode!() |> JSON.decode!() |> Codec.command()

    r = %{id: c.id, descriptor: c.descriptor, dataset_guid: "300"}

    assert {:ok, ^r} =
             r |> Codec.encode_result() |> JSON.encode!() |> JSON.decode!() |> Codec.result()
  end

  test "unknown fields, unsafe endpoints, noncanonical GUIDs and excess batches fail closed" do
    wire = Codec.encode_command(command())

    for key <- ~w(path argv private_key unknown) do
      assert({:error, _} = Codec.command(Map.put(wire, key, "bad")))
    end

    for expires <- [0, -1, 1.5, 9_223_372_036_854_775_808] do
      assert({:error, _} = Codec.command(Map.put(wire, "expires_at", expires)))
    end

    assert {:error, _} =
             Codec.command(put_in(wire["source_endpoint"]["address"], "-oProxyCommand=bad"))

    r = %{"id" => wire["id"], "descriptor" => wire["descriptor"], "dataset_guid" => "300"}

    for guid <- [nil, "0", "0300", "18446744073709551616", 300] do
      assert({:error, _} = Codec.result(Map.put(r, "dataset_guid", guid)))
    end

    assert {:error, _} = Codec.result(Map.put(r, "private_key", "bad"))
    assert {:error, _} = Codec.commands([wire, wire])

    assert {:ok, _} =
             Codec.commands(
               for n <- 1..16 do
                 Map.put(wire, "id", id(n))
               end
             )

    assert {:error, _} =
             Codec.commands(
               for n <- 1..17 do
                 Map.put(wire, "id", id(n))
               end
             )

    assert {:error, _} = Codec.results([r, r])
    message = %{"version" => 4, "session_id" => id(2), "epoch" => 1, "results" => [r]}
    assert {:ok, _} = Codec.exchange(message)
    assert {:error, :unsupported_version} = Codec.exchange(%{message | "version" => 2})
    assert {:error, _} = Codec.exchange(Map.put(message, "extra", true))
  end
end
