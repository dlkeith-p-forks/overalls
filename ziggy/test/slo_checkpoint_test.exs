defmodule Ziggy.SLOCheckpointTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Ziggy.{SLO, SLOCheckpoint}

  @id "01234567-89ab-4def-8123-456789abcdef"

  property "generated terminal aggregates restore exact totals and source lifetime" do
    check all(
            outcomes <- list_of(member_of(~w(completed interrupted cancelled)), max_length: 30),
            duration <- one_of([constant(nil), integer(0..20_000)])
          ) do
      slo =
        Enum.reduce(outcomes, SLO.new(), fn outcome, state ->
          SLO.record(state, %{
            "outcome" => outcome,
            "http_status" => 200,
            "duration_ms" => duration
          })
        end)

      seen = MapSet.new([@id])
      wire = slo |> SLOCheckpoint.wire(seen) |> Jason.encode!() |> Jason.decode!()
      assert {:ok, ^slo, ^seen} = SLOCheckpoint.decode(wire, 1)
      refute inspect(SLO.snapshot(slo)) =~ @id
    end
  end

  property "malformed arithmetic identities and schema cannot restore a counter" do
    check all(
            corruption <- member_of([:count, :buckets, :identity, :duplicate, :foreign, :extra]),
            value <- integer(1..1_000_000)
          ) do
      wire = SLOCheckpoint.wire(SLO.new(), MapSet.new([@id]))

      invalid =
        case corruption do
          :count -> put_in(wire, ["slo", "requests"], value)
          :buckets -> put_in(wire, ["slo", "bucket_counts"], [value, 0, 0, 0, 0, 0, 0, 0])
          :identity -> put_in(wire, ["slo", "incarnation"], "foreign")
          :duplicate -> Map.put(wire, "seen", [@id, @id])
          :foreign -> Map.put(wire, "seen", ["not-a-request-id"])
          :extra -> Map.put(wire, "payload", "excluded")
        end

      assert {:error, :invalid_checkpoint} = SLOCheckpoint.decode(invalid, 2)
    end
  end

  test "private interrupted stage is discarded without replacing committed totals" do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    directory = Path.join(System.tmp_dir!(), "ziggy-checkpoint-#{suffix}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    slo = SLO.new()
    seen = MapSet.new()
    assert :ok = SLOCheckpoint.save(directory, slo, seen, 1)
    stage = Path.join(directory, ".slo-checkpoint.pending")
    File.write!(stage, "interrupted")
    File.chmod!(stage, 0o600)
    assert {:ok, ^slo, ^seen} = SLOCheckpoint.load(directory, 1)
    refute File.exists?(stage)
    File.chmod!(Path.join(directory, ".slo-checkpoint"), 0o644)
    assert {:error, :invalid_checkpoint} = SLOCheckpoint.load(directory, 1)
  end
end
