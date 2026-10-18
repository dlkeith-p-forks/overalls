defmodule Lilly.Transfer.ReadinessProbeTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Transfer.ReadinessProbe
  alias OverallsProtocol.{Checkpoint, Execution, RelocationReadiness}
  @id "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"
  @hash "sha256:" <> String.duplicate("a", 64)

  # @cc [owner:ghuntley,label:verification;security] readiness-resume-exact-checkpoint-model
  # Readiness admission MUST bind the exact retained resume authority and RAM
  # descriptor. These generated substitutions exercise the same predicate used
  # before and after the native readiness wait; they do not prove guest readiness.
  property "memory readiness refuses changed authority, shape and checkpoint identity" do
    generation = Hegel.draw("activation generation", integer(1..1_000_000))
    {command, request} = fixture(generation)
    assert ReadinessProbe.activation_matches?(command, request)

    {field, value} =
      Hegel.draw(
        "substituted activation field",
        member_of([
          {:id, @other},
          {:vm_id, @other},
          {:host_id, @other},
          {:pool_id, @other},
          {:placement_id, @other},
          {:execution_epoch, 3},
          {:generation, generation + 1},
          {:memory_bytes, 1_073_741_824},
          {:kind, :start},
          {:kind, :provision},
          {:checkpoint,
           %{command.checkpoint | state_sha256: "sha256:" <> String.duplicate("b", 64)}}
        ])
      )

    refute ReadinessProbe.activation_matches?(Map.put(command, field, value), request)
    refute ReadinessProbe.activation_matches?(Map.delete(command, :checkpoint), request)
  end

  property "disk-only readiness requires cold start and never accepts a RAM continuation" do
    generation = Hegel.draw("activation generation", integer(1..1_000_000))
    {resume, request} = fixture(generation)
    request = update_in(request.descriptor, &Map.delete(&1, :checkpoint))
    start = resume |> Map.delete(:checkpoint) |> Map.put(:kind, :start)
    assert ReadinessProbe.activation_matches?(start, request)
    refute ReadinessProbe.activation_matches?(resume, request)

    refute ReadinessProbe.activation_matches?(
             Map.put(start, :checkpoint, resume.checkpoint),
             request
           )
  end

  @spec fixture(pos_integer()) :: {Execution.command(), RelocationReadiness.command()}
  defp fixture(generation) do
    checkpoint = %{
      id: @id,
      memory_bytes: 536_870_912,
      state_bytes: 4096,
      compatibility: @hash,
      memory_sha256: @hash,
      state_sha256: @hash,
      manifest_sha256: @hash,
      dataset_guid: "10",
      snapshot_guid: "11"
    }

    assert {:ok, ^checkpoint} = checkpoint |> Checkpoint.encode() |> Checkpoint.decode()

    workload = %{
      image_id: @hash,
      architecture: :x86_64,
      profile: :customer,
      slot: 2,
      vcpu: 1,
      memory_bytes: checkpoint.memory_bytes,
      disk_bytes: 2_147_483_648
    }

    command =
      Map.merge(workload, %{
        id: @id,
        vm_id: @id,
        owner_id: @id,
        host_id: @id,
        pool_id: @id,
        placement_id: @id,
        execution_epoch: 2,
        generation: generation,
        kind: :resume,
        checkpoint: checkpoint
      })

    request = %{
      id: @id,
      generation: generation,
      expires_at: System.system_time(:second) + 180,
      timeout_ms: 1000,
      descriptor: %{
        relocation_id: @id,
        vm_id: @id,
        source_epoch: 1,
        destination_epoch: 2,
        source: %{host_id: @other, pool_id: @other, placement_id: @other},
        destination: %{host_id: @id, pool_id: @id, placement_id: @id},
        workload: workload,
        stream: %{source_dataset_guid: "12", to_guid: "13"},
        checkpoint: checkpoint
      }
    }

    assert {:ok, ^command} = command |> Execution.encode_command() |> Execution.command()

    assert {:ok, ^request} =
             request |> RelocationReadiness.encode_command() |> RelocationReadiness.command()

    {command, request}
  end
end
