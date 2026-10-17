defmodule Lilly.Transfer.SourceSnapshotCleanupTest do
  use ExUnit.Case, async: true
  alias Lilly.Control.{Client, Store}
  alias Lilly.Transfer.SourceSnapshotCleanup
  @moduletag :tmp_dir
  @host "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @placement "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @relocation "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

  test "missing or stale restored authority and invalid leases cause no export or disk effects",
       c do
    root = Path.join(c.tmp_dir, "transfers")
    {:ok, store} = Store.open(Path.join(c.tmp_dir, "control"), @host)

    config = %Lilly.Control.Config{
      client: %Client{host_id: @host, base_url: "https://fixture.invalid", token: "unused"},
      state_dir: c.tmp_dir,
      cgroup_path: "/sys/fs/cgroup/lilly.slice",
      pools: [],
      transfer_state_dir: root
    }

    request = %{
      id: @relocation,
      host_id: @host,
      placement_id: @placement,
      execution_epoch: 1,
      expires_at: System.system_time(:second) + 180
    }

    for bad <- [
          request,
          %{request | host_id: @placement},
          %{request | expires_at: System.system_time(:second) - 1},
          %{request | expires_at: System.system_time(:second) + 301}
        ] do
      assert {:error, :source_snapshot_cleanup_unconfirmed} =
               SourceSnapshotCleanup.execute(config, store, bad)

      refute File.exists?(root)
    end

    command = %{
      id: @host,
      vm_id: @placement,
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: @placement,
      host_id: @host,
      pool_id: @host,
      execution_epoch: 1,
      generation: 100,
      kind: :start,
      architecture: :x86_64,
      profile: :customer,
      slot: 2,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648,
      image_id: "sha256:" <> String.duplicate("a", 64)
    }

    assert {:ok, :stored} = Store.accept(store, command)

    assert {:error, :source_snapshot_cleanup_unconfirmed} =
             SourceSnapshotCleanup.execute(config, store, request)

    assert {:ok, ^command} = Store.read(store, @placement)
    refute File.exists?(root)

    deleted = %{command | id: @relocation, execution_epoch: 2, generation: 101, kind: :delete}
    assert {:ok, :stored} = Store.accept(store, deleted)

    assert {:error, :source_snapshot_cleanup_unconfirmed} =
             SourceSnapshotCleanup.execute(config, store, request)

    assert {:ok, ^deleted} = Store.read(store, @placement)
    refute File.exists?(root)
  end
end
