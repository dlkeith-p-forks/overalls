defmodule OverallsAntithesis.Lilly.ControlledExecutorTest do
  use ExUnit.Case, async: true
  alias OverallsAntithesis.Lilly.{Collector, ControlledExecutor, GuestExecutor, PoolConfig, ZFSIO}
  alias Lilly.Control.Config

  @host "11111111-1111-4111-8111-111111111111"
  @pool "22222222-2222-4222-8222-222222222222"
  @placement "33333333-3333-4333-8333-333333333333"
  @vm "44444444-4444-4444-8444-444444444444"
  @owner "66666666-6666-4666-8666-666666666666"
  @operation "55555555-5555-4555-8555-555555555555"

  @spec raw_command(String.t()) :: map()
  defp raw_command(kind) do
    %{
      "id" => @operation,
      "vm_id" => @vm,
      "owner_id" => @owner,
      "placement_id" => @placement,
      "execution_epoch" => 1,
      "host_id" => @host,
      "pool_id" => @pool,
      "generation" => 1,
      "kind" => kind,
      "architecture" => "x86_64",
      "profile" => "customer",
      "vcpu" => 1,
      "memory_bytes" => 1_073_741_824,
      "disk_bytes" => 2_147_483_648,
      "image_id" => "sha256:" <> String.duplicate("a", 64),
      "slot" => 2
    }
  end

  test "controlled publication is durable but cannot settle a physical outcome" do
    root = Path.join(System.tmp_dir!(), "antithesis-effect-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    config = %Config{
      client: nil,
      state_dir: root,
      cgroup_path: "/sys/fs/cgroup/lilly.slice",
      pools: []
    }

    {:ok, command} = OverallsProtocol.Execution.command(raw_command("delete"))

    assert {:retry, :execution_unavailable} = ControlledExecutor.reconcile(config, command, %{})

    path = ControlledExecutor.proof_path(config, command.id)
    assert {:ok, bytes} = Lilly.Host.PrivateFiles.read_secret(path)

    assert {:ok,
            %{"scope" => "controlled_operation_publication_only", "operation_id" => @operation}} =
             JSON.decode(bytes)

    assert {:retry, :execution_unavailable} = ControlledExecutor.reconcile(config, command, %{})
    assert {:ok, ^bytes} = Lilly.Host.PrivateFiles.read_secret(path)
    assert {:error, :not_launched} = ControlledExecutor.boot_proof(config, command)
    assert :error = ControlledExecutor.watch_target(config, command)
    assert {:error, :terminal_unavailable} = ControlledExecutor.terminal_options(config, command)
    assert {:error, :ingress_unavailable} = ControlledExecutor.open_ingress(config, command, %{})
    assert {:retry, :execution_unavailable} = GuestExecutor.reconcile(config, command, %{})
    assert {:error, :execution_unavailable} = GuestExecutor.boot_proof(config, command)
    assert {:error, :untracked_vm_units} = GuestExecutor.verify_units([command])
  end

  test "hosted pool identity never creates schedulable or native I/O capacity" do
    root = Path.join(System.tmp_dir!(), "antithesis-pool-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    storage = %{
      "backend" => "zfs",
      "zpool_guid" => "10001",
      "dataset_guid" => "10002",
      "dataset" => "overalls/antithesis"
    }

    raw = %{
      "id" => @pool,
      "path" => root,
      "filesystem_id" => "zfs:10001:10002",
      "storage" => storage
    }

    assert {:ok, [pool]} = PoolConfig.decode([raw], @host)
    assert pool.backend == :controlled
    assert pool.template_budget_bytes == 34_359_738_368
    assert pool.image_io_timeout_ms == 300_000

    for {key, value} <- [
          {"logical_budget_bytes", 10_737_418_240},
          {"template_budget_bytes", 0},
          {"image_io_timeout_ms", 999},
          {"image_io_timeout_ms", 14_400_001},
          {"standby_per_image", 1},
          {"standby_fills_per_pass", 4},
          {"standby_retirements_per_pass", 4}
        ] do
      assert :error = PoolConfig.decode([Map.put(raw, key, value)], @host)
    end

    assert :error = PoolConfig.decode([%{raw | "filesystem_id" => "zfs:10001:99999"}], @host)
    assert {:error, :zfs_io_unavailable} = ZFSIO.sample([pool])

    case Collector.sample([pool], "/sys/fs/cgroup/lilly.slice", nil, 1, [], %{}, %{}) do
      {:ok, report, _} ->
        assert report.capacity == nil
        assert report.inventory["execution_ready"] == false
        assert [%{unavailable: true, id: @pool}] = report.pools

      {:error, :collection_failed} ->
        # An unreadable local cgroup withholds the whole report.
        :ok
    end
  end
end
