defmodule OverallsProtocol.StorageTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.Storage
  @id "11111111-1111-4111-8111-111111111111"

  property "ZFS reports preserve unsigned GUIDs and independent physical/logical observations" do
    check all(
            pool_guid <- integer(1..18_446_744_073_709_551_615),
            dataset_guid <- integer(1..18_446_744_073_709_551_615),
            total <- integer(1..9_223_372_036_854_775_807),
            free <- integer(0..total),
            logical <- integer(0..9_223_372_036_854_775_807),
            ratio <- integer(1..100_000),
            quota? <- boolean()
          ) do
      storage = %{
        backend: :zfs,
        zpool_guid: to_string(pool_guid),
        dataset_guid: to_string(dataset_guid),
        dataset: "tank/lilly",
        used_bytes: total - free,
        logical_used_bytes: logical,
        quota_bytes: if(quota?, do: total),
        compression_ratio: ratio / 100
      }

      sample = report(storage, total, free)
      wire = sample |> OverallsProtocol.encode_report() |> JSON.encode!() |> JSON.decode!()
      [pool] = sample.pools

      expected = %{
        sample
        | pools: [%{pool | storage: Map.drop(storage, [:logical_used_bytes, :compression_ratio])}]
      }

      assert {:ok, ^expected} = OverallsProtocol.report(wire)

      assert {:ok, identity} =
               storage
               |> Map.take([:backend, :zpool_guid, :dataset_guid, :dataset])
               |> Storage.encode()
               |> Storage.identity()

      assert Storage.filesystem_id(identity) == "zfs:#{pool_guid}:#{dataset_guid}"

      # Admission observations use v4; native diagnostics remain local.
      assert {:error, :unsupported_version} =
               OverallsProtocol.Execution.exchange(%{
                 "version" => 1,
                 "session_id" => @id,
                 "epoch" => 1,
                 "report" => wire,
                 "acknowledgements" => []
               })

      assert {:ok, %{report: ^expected}} =
               OverallsProtocol.Execution.exchange(%{
                 "version" => 4,
                 "session_id" => @id,
                 "epoch" => 1,
                 "report" => wire,
                 "acknowledgements" => [],
                 "outcomes" => []
               })
    end
  end

  test "wrong identity, quotas, unaccounted bytes and unknown fields fail closed" do
    storage = %{
      backend: :zfs,
      zpool_guid: "1",
      dataset_guid: "2",
      dataset: "tank/lilly",
      used_bytes: 40,
      logical_used_bytes: 100,
      quota_bytes: 100,
      compression_ratio: 2.5
    }

    wire = report(storage, 100, 60) |> OverallsProtocol.encode_report()
    [pool] = wire["pools"]

    for {key, value} <- [
          {"backend", "ext4"},
          {"zpool_guid", "01"},
          {"dataset_guid", "0"},
          {"zpool_guid", "18446744073709551616"},
          {"dataset", "tank"},
          {"dataset", "tank/lilly@snapshot"},
          {"dataset", "tank/../other"},
          {"used_bytes", 39},
          {"logical_used_bytes", -1},
          {"quota_bytes", 99},
          {"quota_bytes", 0},
          {"compression_ratio", 0},
          {"compression_ratio", "2.5"},
          {"extra", true}
        ] do
      changed = put_in(pool, ["storage", key], value)
      assert {:error, :invalid_message} = OverallsProtocol.report(%{wire | "pools" => [changed]})
    end

    excessive = %{pool | "allocations" => %{@id => 41}}
    assert {:error, :invalid_message} = OverallsProtocol.report(%{wire | "pools" => [excessive]})
  end

  property "arbitrary values never decode into identities or observations" do
    check all(value <- one_of([binary(), integer(), list_of(integer())])) do
      assert :error == Storage.identity(value)
      assert :error == Storage.observation(value)
      refute Storage.valid_observation?(value)
    end
  end

  defp report(storage, total, free) do
    %{
      sequence: 1,
      sampled_at: ~U[2026-09-16 12:00:00Z],
      effective_cores: 4,
      effective_memory_bytes: 8_589_934_592,
      inventory: %{
        "architecture" => "x86_64",
        "images" => [],
        "execution_ready" => false,
        "terminal_protocol" => 0,
        "inception_image_id" => nil
      },
      pools: [
        %{
          id: @id,
          total_bytes: total,
          free_bytes: free,
          allocations: %{@id => div(total - free, 2)},
          storage: storage
        }
      ]
    }
  end
end
