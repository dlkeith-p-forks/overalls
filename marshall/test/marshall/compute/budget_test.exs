defmodule Marshall.Compute.BudgetTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Compute.Budget

  property "temporary snapshots remain charged beyond pending disk credit" do
    check all(temporary <- integer(1..1000), materialized <- integer(0..1000)) do
      used = min(temporary, materialized)

      host = %{
        id: "h",
        effective_cores: 8,
        capacity: %{
          "version" => 1,
          "cpu_headroom_millicores" => 8000,
          "memory_headroom_bytes" => 100
        },
        overhead_cores: 0,
        effective_memory_bytes: 100,
        overhead_memory_bytes: 0
      }

      reservation = %{
        host_id: "h",
        pool_id: "p",
        vm_id: "vm",
        placement_id: "copy",
        disk_bytes: 100,
        temporary_disk_bytes: temporary,
        disk_held: true,
        compute_held: false,
        vcpu: 1,
        memory_bytes: 10
      }

      pool = %{
        id: "p",
        backend: :zfs,
        free_bytes: 2000 - used,
        overhead_bytes: 0,
        allocations: %{"copy" => used}
      }

      assert Budget.available(host, pool, [reservation]).disk_bytes ==
               max(0, 1900 - temporary - used + min(100, used))

      # A VM-wide report cannot credit this placement, even for the same workload.
      vm_report = %{pool | allocations: %{"vm" => used}}

      assert Budget.available(host, vm_report, [reservation]).disk_bytes ==
               max(0, 1900 - temporary - used)
    end
  end

  test "two retained placements of one VM receive only their own physical credit" do
    host = %{
      id: "h",
      effective_cores: 8,
      capacity: %{
        "version" => 1,
        "cpu_headroom_millicores" => 8000,
        "memory_headroom_bytes" => 100
      },
      overhead_cores: 0,
      effective_memory_bytes: 100,
      overhead_memory_bytes: 0
    }

    source = %{
      host_id: "h",
      pool_id: "p",
      vm_id: "same-vm",
      placement_id: "source",
      disk_bytes: 100,
      temporary_disk_bytes: 0,
      disk_held: true,
      compute_held: false,
      vcpu: 1,
      memory_bytes: 10
    }

    destination = %{source | placement_id: "destination"}

    pool = %{
      id: "p",
      backend: :zfs,
      free_bytes: 700,
      overhead_bytes: 0,
      allocations: %{"source" => 100, "destination" => 100, "same-vm" => 100}
    }

    assert Budget.available(host, pool, [source, destination]).disk_bytes == 700

    # Snapshot headroom is a physical commitment, not extra guest logical size.
    spacious = %{pool | free_bytes: 10_000}
    copying = %{source | temporary_disk_bytes: 1000}
    assert Budget.available(host, spacious, [copying, destination]).disk_bytes == 9000
    assert Budget.physical_disk_available(host, spacious, [copying, destination]) == 9000
  end

  property "materializing reserved disks never charges space twice or credits orphan disks" do
    check all(
            sizes <- list_of(integer(1..1000), min_length: 1, max_length: 15),
            fraction <- integer(0..100),
            orphan <- integer(0..1000),
            overhead <- integer(0..1000)
          ) do
      reservations =
        Enum.with_index(sizes, fn size, index ->
          %{
            host_id: "h",
            pool_id: "p",
            temporary_disk_bytes: 0,
            placement_id: "#{index}",
            disk_bytes: size,
            vcpu: 1,
            memory_bytes: 10,
            disk_held: true,
            compute_held: true
          }
        end)

      allocations = Map.new(reservations, &{&1.placement_id, div(&1.disk_bytes * fraction, 100)})
      materialized = Enum.sum(Map.values(allocations))

      host = %{
        id: "h",
        effective_cores: 20,
        capacity: %{
          "version" => 1,
          "cpu_headroom_millicores" => 20000,
          "memory_headroom_bytes" => 1000
        },
        overhead_cores: 2,
        effective_memory_bytes: 1000,
        overhead_memory_bytes: 100
      }

      pool = %{
        id: "p",
        backend: :zfs,
        total_bytes: 20_000,
        free_bytes: 20_000 - materialized - orphan,
        overhead_bytes: overhead,
        allocations: Map.put(allocations, "orphan", orphan)
      }

      budget = Budget.available(host, pool, reservations)
      assert budget.disk_bytes == max(0, 20_000 - orphan - overhead - Enum.sum(sizes))
      assert budget.vcpu == max(0, 18 - length(sizes))
      assert budget.memory_bytes == max(0, 900 - 10 * length(sizes))
    end
  end

  property "physical usage gates admission independently of legacy logical budgets" do
    check all(
            commitment <- integer(1..100_000),
            allocated <- integer(0..commitment),
            free <- integer(0..100_000),
            overhead <- integer(0..1000),
            orphan <- integer(0..100_000)
          ) do
      host = %{
        id: "h",
        effective_cores: 8,
        capacity: %{
          "version" => 1,
          "cpu_headroom_millicores" => 8000,
          "memory_headroom_bytes" => 1000
        },
        overhead_cores: 0,
        effective_memory_bytes: 1000,
        overhead_memory_bytes: 0
      }

      pool = %{
        id: "p",
        backend: :zfs,
        total_bytes: free + allocated + orphan,
        free_bytes: free,
        overhead_bytes: overhead,
        allocations: %{"vm" => allocated, "orphan" => orphan}
      }

      reservation = %{
        host_id: "h",
        pool_id: "p",
        temporary_disk_bytes: 0,
        placement_id: "vm",
        disk_bytes: commitment,
        disk_held: true,
        compute_held: false,
        vcpu: 1,
        memory_bytes: 10
      }

      remaining = Budget.available(host, pool, [reservation]).disk_bytes
      assert remaining == max(0, free + allocated - overhead - commitment)
      assert remaining <= max(0, free - overhead)

      compressed = %{
        pool
        | free_bytes: free + allocated,
          allocations: %{"vm" => 0, "orphan" => orphan}
      }

      # total_bytes is not the logical cap and compression does not free a commitment.
      assert Budget.available(host, compressed, [reservation]).disk_bytes == remaining
      # Once the reservation is gone, only observed free bytes may be admitted.
      assert Budget.available(host, pool, []).disk_bytes == max(0, free - overhead)
    end
  end

  test "a confirmed stopped reservation retains disk while releasing compute" do
    host = %{
      id: "h",
      effective_cores: 4,
      capacity: %{
        "version" => 1,
        "cpu_headroom_millicores" => 4000,
        "memory_headroom_bytes" => 100
      },
      overhead_cores: 1,
      effective_memory_bytes: 100,
      overhead_memory_bytes: 10
    }

    pool = %{
      id: "p",
      backend: :zfs,
      total_bytes: 100,
      free_bytes: 60,
      overhead_bytes: 5,
      allocations: %{"vm" => 40}
    }

    reservation = %{
      host_id: "h",
      pool_id: "p",
      temporary_disk_bytes: 0,
      placement_id: "vm",
      disk_bytes: 60,
      vcpu: 3,
      memory_bytes: 90,
      disk_held: true,
      compute_held: false
    }

    assert Budget.available(host, pool, [reservation]) == %{
             vcpu: 3,
             memory_bytes: 90,
             disk_bytes: 35
           }
  end

  test "over-limit materialization cannot create additional disk credit" do
    host = %{
      id: "h",
      effective_cores: 4,
      capacity: %{
        "version" => 1,
        "cpu_headroom_millicores" => 4000,
        "memory_headroom_bytes" => 100
      },
      overhead_cores: 1,
      effective_memory_bytes: 100,
      overhead_memory_bytes: 10
    }

    pool = %{
      id: "p",
      backend: :zfs,
      total_bytes: 100,
      free_bytes: 30,
      overhead_bytes: 0,
      allocations: %{"vm" => 70}
    }

    reservation = %{
      host_id: "h",
      pool_id: "p",
      temporary_disk_bytes: 0,
      placement_id: "vm",
      disk_bytes: 50,
      vcpu: 3,
      memory_bytes: 90,
      disk_held: true,
      compute_held: true
    }

    assert Budget.available(host, pool, [reservation]).disk_bytes == 30

    refute Budget.fits?(Budget.available(host, pool, [reservation]), %{
             vcpu: 1,
             memory_bytes: 1,
             disk_bytes: 1
           })
  end
end
