defmodule OverallsAntithesis.Lilly.GuestStubStorageTest do
  use ExUnit.Case, async: false

  alias OverallsAntithesis.Lilly.{StubStorageCollector, StubStorageHealth}
  alias Lilly.Control.Config
  alias Lilly.Host.Pool

  @pool "22222222-2222-4222-8222-222222222222"
  @placement "33333333-3333-4333-8333-333333333333"
  @outcome "55555555-5555-4555-8555-555555555555"
  @image "sha256:" <> String.duplicate("a", 64)
  @storage %{
    backend: :zfs,
    zpool_guid: "10001",
    dataset_guid: "10002",
    dataset: "overalls/antithesis"
  }
  @limits %{effective_cores: 4, effective_memory_bytes: 8_589_934_592}
  @proof %{
    "execution_epoch" => 1,
    "generation" => 2,
    "outcome_id" => @outcome,
    "compute" => true,
    "disk" => true
  }

  setup do
    socket = "/tmp/kst-#{System.unique_integer([:positive])}.sock"
    previous = System.get_env("OVERALLS_ANTITHESIS_GUEST_SOCKET")
    System.put_env("OVERALLS_ANTITHESIS_GUEST_SOCKET", socket)

    on_exit(fn ->
      if previous,
        do: System.put_env("OVERALLS_ANTITHESIS_GUEST_SOCKET", previous),
        else: System.delete_env("OVERALLS_ANTITHESIS_GUEST_SOCKET")

      File.rm(socket)
    end)

    pool = %Pool{
      id: @pool,
      path: "/var/lib/lilly/pool",
      filesystem_id: "zfs:10001:10002",
      storage: @storage,
      backend: :controlled
    }

    %{
      socket: socket,
      pool: pool,
      config: %Config{
        client: nil,
        state_dir: "/tmp",
        cgroup_path: "/sys/fs/cgroup/lilly.slice",
        pools: [pool]
      }
    }
  end

  test "free guest slot yields bounded headroom and a synthetic unused stub pool", %{pool: pool} do
    report = StubStorageCollector.report([pool], @limits, "x86_64", 3, [], %{}, [])

    assert report.capacity["cpu_headroom_millicores"] == 1000
    assert report.capacity["memory_headroom_bytes"] == 2_147_483_648
    assert report.capacity["covered"] == %{}
    assert OverallsProtocol.Capacity.valid?(report.capacity)
    assert report.inventory["execution_ready"] == false

    assert [%{id: @pool, total_bytes: total, free_bytes: total, allocations: %{}} = entry] =
             report.pools

    assert entry.storage.used_bytes == 0
    assert OverallsProtocol.Storage.coherent?(entry.storage, total, total)
    assert StubStorageCollector.stub_pool?(pool, entry)
    refute StubStorageCollector.stub_pool?(pool, %{entry | allocations: %{@placement => 1}})
  end

  test "occupied or uncertain guest slot removes headroom; limits cap it", %{pool: pool} do
    for state <- ["running", "degraded", "uncertain"] do
      entry = guest(state, state == "running", 1, 2)
      report = StubStorageCollector.report([pool], @limits, "x86_64", 1, [], %{}, [entry])
      assert report.capacity["cpu_headroom_millicores"] == 0
      assert report.capacity["memory_headroom_bytes"] == 0
    end

    stopped = guest("stopped", false, nil, nil)
    small = %{effective_cores: 1, effective_memory_bytes: 1_073_741_824}
    report = StubStorageCollector.report([pool], small, "x86_64", 1, [], %{}, [stopped])
    assert report.capacity["memory_headroom_bytes"] == 1_073_741_824
  end

  test "coverage survives only for the exact live tuple or a stopped placement", %{pool: pool} do
    coverage = %{@placement => @proof}
    live = guest("running", true, 1, 2)
    stale = guest("running", true, 1, 3)

    assert StubStorageCollector.report([pool], @limits, "x86_64", 1, [], coverage, [live]).capacity[
             "covered"
           ] == coverage

    assert StubStorageCollector.report([pool], @limits, "x86_64", 1, [], coverage, [stale]).capacity[
             "covered"
           ] == %{}

    assert StubStorageCollector.report([pool], @limits, "x86_64", 1, [], coverage, []).capacity[
             "covered"
           ] == %{}

    stopped = guest("stopped", false, nil, nil)

    assert StubStorageCollector.report([pool], @limits, "x86_64", 1, [], coverage, [stopped]).capacity[
             "covered"
           ] == coverage
  end

  test "readiness requires stub pools, advertised image and guest-vmm health", ctx do
    report = %{
      StubStorageCollector.report([ctx.pool], @limits, "x86_64", 1, [], %{}, [])
      | inventory: %{"images" => [@image]}
    }

    refute StubStorageHealth.ready?(ctx.config, report)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {:local, ctx.socket}])

    healthy = %{
      "state" => "ok",
      "image_id" => @image,
      "inventory_valid" => true,
      "state_writable" => true,
      "state_root" => "/var/lib/overalls-tcg"
    }

    server =
      Task.async(fn ->
        respond(listener, healthy)
        respond(listener, %{healthy | "state_root" => "/pool/guest-emulator"})
        respond(listener, %{healthy | "image_id" => "sha256:" <> String.duplicate("b", 64)})
      end)

    assert StubStorageHealth.ready?(ctx.config, report)
    refute StubStorageHealth.ready?(ctx.config, report)
    refute StubStorageHealth.ready?(ctx.config, report)
    Task.await(server)
    :gen_tcp.close(listener)

    refute StubStorageHealth.ready?(ctx.config, %{report | capacity: nil})

    refute StubStorageHealth.ready?(ctx.config, %{
             report
             | pools: [%{id: @pool, unavailable: true, storage: @storage}]
           })

    refute StubStorageHealth.ready?(%{ctx.config | pools: [%{ctx.pool | backend: :zfs}]}, report)
  end

  @spec guest(String.t(), boolean(), pos_integer() | nil, pos_integer() | nil) :: map()
  defp guest(state, live, epoch, generation) do
    %{
      "placement_id" => @placement,
      "execution_epoch" => epoch,
      "generation" => generation,
      "state" => state,
      "live" => live,
      "overlay_present" => true,
      "qemu_pid" => if(live, do: 10),
      "backend_pid" => if(live, do: 11)
    }
  end

  @spec respond(:gen_tcp.listen_socket(), map()) :: :ok
  defp respond(listener, value) do
    {:ok, socket} = :gen_tcp.accept(listener, 10_000)
    {:ok, line} = :gen_tcp.recv(socket, 0, 10_000)
    {:ok, %{"operation" => "health"}} = JSON.decode(line)
    :ok = :gen_tcp.send(socket, JSON.encode!(value) <> "\n")
    :gen_tcp.close(socket)
  end
end
