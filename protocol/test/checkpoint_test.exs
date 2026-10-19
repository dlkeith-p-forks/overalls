defmodule OverallsProtocol.CheckpointTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import Hegel.Gen
  import OverallsProtocol.TestProperties, only: [draw: 2]
  alias OverallsProtocol.{Checkpoint, Execution, Relocation}
  @id "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"
  @hash "sha256:" <> String.duplicate("a", 64)

  property "full checkpoint identities round trip bounded MiB-aligned RAM" do
    memory = draw("memory MiB", integer(512..262_144)) * 1_048_576
    state = draw("device state bytes", integer(1..67_043_328))
    descriptor = %{checkpoint() | memory_bytes: memory, state_bytes: state}
    assert {:ok, ^descriptor} = descriptor |> Checkpoint.encode() |> Checkpoint.decode()
    assert Checkpoint.storage_bytes(memory) == memory + 67_108_864
  end

  property "unknown fields and broken digest identities cannot authorize a continuation" do
    key =
      draw("untrusted field", member_of(~w(path boot_challenge command authority memory_path)))

    value = checkpoint() |> Checkpoint.encode() |> Map.put(key, "fixture")
    assert {:error, :invalid_checkpoint} = Checkpoint.decode(value)
    digest = draw("invalid digest", member_of([nil, "", "sha256:abc", String.duplicate("f", 64)]))

    assert {:error, :invalid_checkpoint} =
             Checkpoint.decode(Map.put(Checkpoint.encode(checkpoint()), "memory_sha256", digest))
  end

  property "disk and RAM allocation credits share one physical used-space bound" do
    disk = draw("physical disk bytes", integer(0..1_000_000))
    ram = draw("physical RAM bytes", integer(0..1_000_000))
    used = disk + ram

    pool = %{
      id: @id,
      total_bytes: used + 1,
      free_bytes: 1,
      allocations: %{@id => disk},
      checkpoint_allocations: %{@id => ram},
      storage: %{
        backend: :zfs,
        zpool_guid: "1",
        dataset_guid: "2",
        dataset: "tank/lilly",
        used_bytes: used,
        quota_bytes: used + 1
      }
    }

    report = %{
      sequence: 1,
      sampled_at: ~U[2026-10-18 00:00:00Z],
      effective_cores: 1,
      effective_memory_bytes: 536_870_912,
      inventory: %{
        "architecture" => "x86_64",
        "images" => [],
        "execution_ready" => false,
        "terminal_protocol" => 0,
        "inception_image_id" => nil,
        "checkpoint_image_ids" => [@hash],
        "checkpoint_compatibility" => @hash
      },
      pools: [pool]
    }

    wire = OverallsProtocol.encode_report(report)
    assert {:ok, ^report} = OverallsProtocol.report(wire)

    for invalid <- [
          nil,
          [@hash, @hash],
          ["linux"],
          Enum.map(1..257, fn n ->
            "sha256:" <> String.pad_leading(Integer.to_string(n, 16), 64, "0")
          end)
        ] do
      assert {:error, :invalid_message} =
               OverallsProtocol.report(
                 put_in(wire, ["inventory", "checkpoint_image_ids"], invalid)
               )
    end

    assert {:error, :invalid_message} =
             OverallsProtocol.report(
               update_in(wire, ["inventory"], &Map.delete(&1, "checkpoint_image_ids"))
             )

    [encoded] = wire["pools"]
    excessive = put_in(encoded, ["checkpoint_allocations", @id], ram + 1)
    assert {:error, :invalid_message} = OverallsProtocol.report(%{wire | "pools" => [excessive]})

    assert {:error, :invalid_message} =
             OverallsProtocol.report(%{
               wire
               | "pools" => [Map.delete(encoded, "checkpoint_allocations")]
             })

    assert {:error, :invalid_message} =
             OverallsProtocol.report(
               update_in(wire, ["inventory"], &Map.delete(&1, "checkpoint_compatibility"))
             )
  end

  test "pause facts require immutable RAM and exact released-compute facts" do
    outcome = %{
      id: @id,
      vm_id: @id,
      placement_id: @id,
      execution_epoch: 1,
      operation_id: @id,
      generation: 2,
      sequence: 1,
      state: :paused,
      compute_empty: true,
      disk_present: true,
      cleanup_complete: false,
      reason: :none,
      checkpoint: checkpoint()
    }

    wire = Execution.encode_outcome(outcome)
    assert {:ok, ^outcome} = Execution.outcome(wire)

    for change <- [
          %{"compute_empty" => false},
          %{"disk_present" => false},
          %{"cleanup_complete" => true},
          %{"guest_ready" => true}
        ] do
      assert {:error, :invalid_message} = Execution.outcome(Map.merge(wire, change))
    end

    assert {:error, :invalid_message} = Execution.outcome(Map.delete(wire, "checkpoint"))
  end

  test "resume requires exact checkpoint shape and cold start rejects RAM" do
    command = %{
      id: @id,
      owner_id: @id,
      vm_id: @id,
      host_id: @id,
      pool_id: @id,
      placement_id: @id,
      execution_epoch: 2,
      generation: 3,
      kind: :resume,
      image_id: @hash,
      architecture: :x86_64,
      profile: :customer,
      slot: 2,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 4_294_967_296,
      checkpoint: checkpoint()
    }

    wire = Execution.encode_command(command)
    assert wire["checkpoint"] == Checkpoint.encode(command.checkpoint)
    assert {:ok, ^command} = Execution.command(wire)
    assert {:error, :invalid_message} = Execution.command(Map.delete(wire, "checkpoint"))

    assert {:error, :invalid_message} =
             Execution.command(Map.put(wire, "memory_bytes", 1_073_741_824))

    assert {:error, :invalid_message} = Execution.command(Map.put(wire, "kind", "start"))

    assert {:error, :invalid_message} =
             Execution.command(Map.put(wire, "checkpoint", command.checkpoint))

    # Both codecs must compose without allowing attribution to authorize a new
    # identity on memory continuation: identity belongs to provision/start only.
    {:ok, identity} =
      OverallsProtocol.GitIdentity.validate(%{name: "Author", email: "author@example.test"})

    combined = Execution.encode_command(Map.put(command, :git_identity, identity))
    assert combined["checkpoint"] == Checkpoint.encode(command.checkpoint)
    assert combined["git_identity"] == OverallsProtocol.GitIdentity.encode(identity)
    assert {:error, :invalid_message} = Execution.command(combined)
  end

  test "RAM relocation remains an inert component and clones reject it" do
    intent = %{
      relocation_id: @id,
      vm_id: @id,
      source: %{placement_id: @id, host_id: @id, pool_id: @id},
      destination: %{placement_id: @other, host_id: @other, pool_id: @other},
      source_epoch: 1,
      destination_epoch: 2,
      checkpoint: checkpoint(),
      workload: %{
        image_id: @hash,
        architecture: :x86_64,
        profile: :customer,
        slot: 2,
        vcpu: 1,
        memory_bytes: 536_870_912,
        disk_bytes: 4_294_967_296
      }
    }

    assert {:ok, ^intent} = intent |> Relocation.encode_intent() |> Relocation.intent()
    descriptor = Map.put(intent, :stream, %{source_dataset_guid: "10", to_guid: "11"})
    wire = Relocation.encode_descriptor(descriptor)
    assert {:ok, ^descriptor} = Relocation.descriptor(wire)

    assert {:error, :invalid_message} =
             OverallsProtocol.DiskTransfer.descriptor(Map.put(wire, "purpose", "clone"))
  end

  @spec checkpoint() :: Checkpoint.t()
  defp checkpoint,
    do: %{
      id: @id,
      memory_bytes: 536_870_912,
      state_bytes: 4096,
      compatibility: @hash,
      memory_sha256: @hash,
      state_sha256: @hash,
      manifest_sha256: @hash,
      dataset_guid: "3",
      snapshot_guid: "4"
    }
end
