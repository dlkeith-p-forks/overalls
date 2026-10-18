defmodule Marshall.Compute.EnrollmentRequestTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Compute.EnrollmentRequest

  property "bounded requests preserve overheads and reject duplicate filesystems or extra fields" do
    cores = draw("cores", integer(0..65536))
    memory = draw("memory", integer(0..9_223_372_036_854_775_806))
    ttl = draw("ttl", integer(1..157_680_000))
    name = draw("name", string(:alphanumeric, min_length: 1, max_length: 128))

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

  property "ZFS enrollment binds unsigned GUIDs and refuses a retired budget or unknown pool key" do
    guid = draw("guid", positive_uint64())
    overhead = draw("overhead", integer(0..9_223_372_036_854_775_806))
    budget = draw("budget", one_of([integer(), constant(nil), binary()]))

    key =
      draw(
        "key",
        filter(
          string(:alphanumeric, min_length: 1, max_length: 32),
          &(&1 not in ~w(name storage overhead_bytes))
        )
      )

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

  property "arbitrary terms never become an enrollment request" do
    value = draw("value", one_of([binary(), integer(), list_of(integer())]))
    assert {:error, :invalid_enrollment_request} = EnrollmentRequest.parse(value)
  end

  # @cc [owner:ghuntley,label:verification] enrollment-generated-unsigned-width
  # Enrollment GUID generation MUST retain every nonzero unsigned 64-bit value,
  # including the upper half beyond the native engine's signed integer bound.
  @spec positive_uint64() :: :hegel_gen.t(pos_integer())
  defp positive_uint64 do
    tuple([integer(0, 0xFFFFFFFF), integer(0, 0xFFFFFFFF)])
    |> map(fn {high, low} -> high * 0x100000000 + low end)
    |> filter(&(&1 > 0))
  end
end
