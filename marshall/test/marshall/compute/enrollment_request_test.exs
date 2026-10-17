defmodule Marshall.Compute.EnrollmentRequestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Marshall.Compute.EnrollmentRequest

  property "bounded requests preserve overheads and reject duplicate filesystems or extra fields" do
    check all(
            cores <- integer(0..65_536),
            memory <- integer(0..9_223_372_036_854_775_806),
            ttl <- integer(1..157_680_000),
            name <- string(:alphanumeric, min_length: 1, max_length: 128)
          ) do
      pool = %{
        "name" => "guests",
        "overhead_bytes" => memory,
        "storage" => %{
          "backend" => "zfs",
          "zpool_guid" => "1",
          "dataset_guid" => "2",
          "dataset" => "tank/lilly"
        }
      }

      input = %{
        "version" => 3,
        "name" => name,
        "machine_id" => "sha256:" <> String.duplicate("a", 64),
        "architecture" => "x86_64",
        "overhead_cores" => cores,
        "overhead_memory_bytes" => memory,
        "credential_ttl_seconds" => ttl,
        "pools" => [pool]
      }

      assert {:ok, parsed} = EnrollmentRequest.parse(input)
      assert parsed.host.overhead_cores == cores
      assert parsed.host.overhead_memory_bytes == memory

      assert {:error, :invalid_enrollment_request} =
               EnrollmentRequest.parse(Map.put(input, "enabled", true))

      assert {:error, :invalid_enrollment_request} =
               EnrollmentRequest.parse(
                 Map.put(input, "pools", [pool, Map.put(pool, "name", "second")])
               )

      assert {:error, :invalid_enrollment_request} =
               EnrollmentRequest.parse(Map.put(input, "credential_ttl_seconds", 157_680_001))
    end
  end

  property "ZFS enrollment binds unsigned GUIDs and refuses a retired budget or unknown pool key" do
    check all(
            guid <- integer(1..18_446_744_073_709_551_615),
            overhead <- integer(0..9_223_372_036_854_775_806),
            budget <- one_of([integer(), constant(nil), binary()]),
            key <- string(:alphanumeric, min_length: 1, max_length: 32),
            key not in ~w(name storage overhead_bytes)
          ) do
      storage = %{
        "backend" => "zfs",
        "zpool_guid" => to_string(guid),
        "dataset_guid" => "123",
        "dataset" => "tank/lilly"
      }

      pool = %{"name" => "guests", "storage" => storage, "overhead_bytes" => overhead}

      input = %{
        "version" => 3,
        "name" => "zfs-host",
        "architecture" => "x86_64",
        "machine_id" => "sha256:" <> String.duplicate("a", 64),
        "overhead_cores" => 1,
        "overhead_memory_bytes" => 0,
        "credential_ttl_seconds" => 3600,
        "pools" => [pool]
      }

      assert {:ok, %{pools: [parsed]}} = EnrollmentRequest.parse(input)
      assert parsed.backend == :zfs
      assert parsed.filesystem_id == "zfs:#{guid}:123"
      assert parsed.overhead_bytes == overhead
      refute Map.has_key?(parsed, :logical_budget_bytes)

      assert {:error, :invalid_enrollment_request} =
               EnrollmentRequest.parse(%{input | "version" => 1})

      alias_pool = %{
        pool
        | "name" => "alias",
          "storage" => %{storage | "dataset_guid" => "456", "dataset" => "tank/other"}
      }

      assert {:error, :invalid_enrollment_request} =
               EnrollmentRequest.parse(%{input | "pools" => [pool, alias_pool]})

      # A budget is refused whatever its value, including one that the Push 5
      # release would have validated and discarded (positive, above headroom).
      for changed <- [
            Map.put(pool, "logical_budget_bytes", budget),
            Map.put(pool, "logical_budget_bytes", overhead + 1),
            Map.put(pool, key, 1),
            Map.put(pool, "overhead_bytes", -1),
            Map.put(pool, "filesystem_id", "ext4:123")
          ] do
        assert {:error, :invalid_enrollment_request} =
                 EnrollmentRequest.parse(%{input | "pools" => [changed]})
      end
    end
  end

  property "arbitrary terms never become an enrollment request" do
    check all(value <- one_of([binary(), integer(), list_of(integer())])) do
      assert {:error, :invalid_enrollment_request} = EnrollmentRequest.parse(value)
    end
  end
end
