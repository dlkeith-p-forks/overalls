defmodule OverallsAntithesis.Lilly.StubStorageTest do
  use ExUnit.Case, async: true

  alias Lilly.Host.Inventory
  alias OverallsAntithesis.Lilly.{Collector, PoolConfig, StubStorage}

  @moduletag :tmp_dir
  @host "11111111-1111-4111-8111-111111111111"
  @pool "22222222-2222-4222-8222-222222222222"
  @total 68_719_476_736
  @free 51_539_607_552

  test "only an explicit, private, exact stub file selects the substrate", %{tmp_dir: root} do
    assert StubStorage.read(nil) == :disabled
    path = write_stub(root, substrate(root))
    assert {:ok, stub} = StubStorage.read(path)
    assert stub.total_bytes == @total and stub.free_bytes == @free
    assert stub.identity.backend == :zfs

    File.chmod!(path, 0o640)
    assert StubStorage.read(path) == {:error, :stub_storage_invalid}
    File.chmod!(path, 0o600)

    for change <- [
          %{"scope" => "native-zfs"},
          %{"free_bytes" => @total + 1},
          %{"zpool_guid" => "0"},
          %{"image_path" => "relative"},
          %{"extra" => true}
        ] do
      File.write!(path, JSON.encode!(Map.merge(substrate(root), change)))
      assert StubStorage.read(path) == {:error, :stub_storage_invalid}
    end

    assert StubStorage.read(Path.join(root, "missing.json")) == {:error, :stub_storage_invalid}
  end

  test "pool entries credit only the enrolled identity with coherent stub totals", %{
    tmp_dir: root
  } do
    {:ok, stub} = StubStorage.read(write_stub(root, substrate(root)))
    pool = pool(root)
    report = StubStorage.pool_report(pool, stub)
    assert report.total_bytes == @total and report.free_bytes == @free
    assert report.allocations == %{}
    assert OverallsProtocol.Storage.coherent?(report.storage, @total, @free)

    foreign = %{pool | storage: %{pool.storage | dataset_guid: "99999"}}

    assert StubStorage.pool_report(foreign, stub) == %{
             id: @pool,
             unavailable: true,
             storage: foreign.storage
           }
  end

  test "the stub image is advertised only after Lilly's digest verification", %{tmp_dir: root} do
    image = stub_image(root)
    {:ok, stub} = StubStorage.read(write_stub(root, substrate(root, image)))
    assert [id] = StubStorage.image_ids(stub)
    assert "sha256:" <> _ = id

    File.chmod!(Path.join(image, "kernel"), 0o644)
    File.write!(Path.join(image, "kernel"), "tampered kernel placeholder bytes!!\n")
    File.chmod!(Path.join(image, "kernel"), 0o444)
    assert StubStorage.image_ids(stub) == []
  end

  test "readiness needs a selected stub, measured compute and observed pools", %{tmp_dir: root} do
    {:ok, stub} = StubStorage.read(write_stub(root, substrate(root)))
    observed = StubStorage.pool_report(pool(root), stub)

    report = %{
      capacity: %{"version" => 1},
      pools: [observed],
      inventory: %{"images" => ["sha256:" <> String.duplicate("a", 64)]}
    }

    assert StubStorage.ready?(report, {:ok, stub})
    refute StubStorage.ready?(report, :disabled)
    refute StubStorage.ready?(report, {:error, :stub_storage_invalid})
    refute StubStorage.ready?(%{report | capacity: nil}, {:ok, stub})
    refute StubStorage.ready?(%{report | inventory: %{"images" => []}}, {:ok, stub})

    unavailable = %{id: @pool, unavailable: true, storage: observed.storage}
    refute StubStorage.ready?(%{report | pools: [unavailable]}, {:ok, stub})
  end

  test "stub samples keep compute measured and the disabled path unavailable", %{tmp_dir: root} do
    cgroup = Path.join(root, "cgroup")
    leaf = Path.join(cgroup, "lilly")
    File.mkdir_p!(leaf)
    File.write!(Path.join(cgroup, "cgroup.subtree_control"), "cpu memory\n")
    File.write!(Path.join(cgroup, "cpu.stat"), "usage_usec 100\n")
    File.write!(Path.join(leaf, "cpu.stat"), "usage_usec 50\n")
    File.write!(Path.join(leaf, "cpu.max"), "max 100000\n")
    File.write!(Path.join(leaf, "memory.max"), "max\n")
    File.write!(Path.join(leaf, "memory.current"), "1024\n")
    limits = %{effective_cores: 2, effective_memory_bytes: 4_294_967_296}
    pools = [pool(root)]
    {:ok, stub} = StubStorage.read(write_stub(root, substrate(root, stub_image(root))))

    assert {nil, nil, [%{unavailable: true}], []} =
             Collector.stub_sample(:disabled, pools, cgroup, leaf, inventory(), limits, nil, %{})

    assert {nil, nil, [%{unavailable: true}], []} =
             Collector.stub_sample(
               {:error, :stub_storage_invalid},
               pools,
               cgroup,
               leaf,
               inventory(),
               limits,
               nil,
               %{}
             )

    assert {nil, first, [%{total_bytes: @total}], [_image]} =
             Collector.stub_sample(
               {:ok, stub},
               pools,
               cgroup,
               leaf,
               inventory(),
               limits,
               nil,
               %{}
             )

    Process.sleep(2)
    File.write!(Path.join(leaf, "cpu.stat"), "usage_usec 60\n")
    File.write!(Path.join(cgroup, "cpu.stat"), "usage_usec 110\n")

    assert {%{"version" => 1} = capacity, _usage, _pools, _images} =
             Collector.stub_sample(
               {:ok, stub},
               pools,
               cgroup,
               leaf,
               inventory(),
               limits,
               %{usage: first},
               %{}
             )

    assert capacity["cpu_headroom_millicores"] <= 2000
    assert capacity["memory_headroom_bytes"] <= 4_294_967_296
  end

  @spec substrate(Path.t(), Path.t() | nil) :: map()
  defp substrate(root, image \\ nil) do
    %{
      "version" => 1,
      "scope" => "antithesis-harness-stub-not-zfs",
      "zpool_guid" => "10001",
      "dataset_guid" => "10002",
      "dataset" => "overalls/antithesis",
      "total_bytes" => @total,
      "free_bytes" => @free,
      "image_path" => image || Path.join(root, "stub-image")
    }
  end

  @spec write_stub(Path.t(), map()) :: Path.t()
  defp write_stub(root, value) do
    path = Path.join(root, "storage-stub.json")
    File.write!(path, JSON.encode!(value))
    File.chmod!(path, 0o600)
    path
  end

  @spec pool(Path.t()) :: Lilly.Host.Pool.t()
  defp pool(root) do
    path = Path.join(root, "pool")
    File.mkdir_p!(path)

    raw = %{
      "id" => @pool,
      "path" => path,
      "filesystem_id" => "zfs:10001:10002",
      "storage" => %{
        "backend" => "zfs",
        "zpool_guid" => "10001",
        "dataset_guid" => "10002",
        "dataset" => "overalls/antithesis"
      }
    }

    {:ok, [pool]} = PoolConfig.decode([raw], @host)
    pool
  end

  @spec stub_image(Path.t()) :: Path.t()
  defp stub_image(root) do
    directory = Path.join(root, "stub-image")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o755)

    files = %{
      "kernel" => "overalls antithesis admission-stub kernel placeholder; not bootable\n",
      "initrd" => "overalls antithesis admission-stub initrd placeholder; not bootable\n",
      "rootfs.ext4" => :binary.copy(<<0>>, 4096)
    }

    descriptors =
      Map.new(files, fn {name, bytes} ->
        File.write!(Path.join(directory, name), bytes)
        File.chmod!(Path.join(directory, name), 0o444)

        {name,
         %{
           "bytes" => byte_size(bytes),
           "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
         }}
      end)

    manifest = %{
      "version" => 4,
      "architecture" => "x86_64",
      "boot_args" => "console=ttyS0 overalls.antithesis.storage_stub=1",
      "minimum_memory_bytes" => 536_870_912,
      "minimum_disk_bytes" => 1_073_741_824,
      "kernel" => descriptors["kernel"],
      "initrd" => descriptors["initrd"],
      "rootfs" => descriptors["rootfs.ext4"],
      "workspace_source_version" => nil
    }

    File.write!(Path.join(directory, "manifest.json"), JSON.encode!(manifest))
    File.chmod!(Path.join(directory, "manifest.json"), 0o444)
    directory
  end

  @spec inventory() :: Inventory.t()
  defp inventory do
    %Inventory{
      architecture: "x86_64",
      logical_cores: 4,
      memory: %{
        total_bytes: 8_589_934_592,
        free_bytes: 4_294_967_296,
        available_bytes: 4_294_967_296,
        used_bytes: 4_294_967_296,
        utilization_percent: 50.0
      }
    }
  end
end
