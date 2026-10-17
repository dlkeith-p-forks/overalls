defmodule Marshall.Compute.ZfsPoolsTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Compute.{Budget, Host, HostReports, Ledger, StoragePool}
  @gib 1_073_741_824

  setup do
    base = host_fixture()

    pool =
      Ledger.create!(StoragePool, :enroll, %{
        host_id: base.host.id,
        name: "zfs-guests",
        backend: :zfs,
        filesystem_id: "zfs:123:456",
        zpool_guid: "123",
        dataset_guid: "456",
        dataset: "tank/lilly",
        overhead_bytes: @gib
      })

    observation = %{
      backend: :zfs,
      zpool_guid: "123",
      dataset_guid: "456",
      dataset: "tank/lilly",
      used_bytes: @gib,
      logical_used_bytes: 3 * @gib,
      quota_bytes: 100 * @gib,
      compression_ratio: 3.0
    }

    snapshot = %{
      id: pool.id,
      total_bytes: 100 * @gib,
      free_bytes: 99 * @gib,
      allocations: %{},
      storage: observation
    }

    report = %{base.report | sequence: 2, pools: base.report.pools ++ [snapshot]}
    Map.merge(base, %{zfs: pool, zfs_report: report, snapshot: snapshot})
  end

  test "reports reject identity/accounting changes atomically", context do
    %{host: host, epoch: epoch, zfs: pool, zfs_report: report, snapshot: snapshot} = context
    assert {:ok, :ok} = HostReports.ingest(host.id, epoch, report)
    assert [stored] = Ledger.read!(StoragePool, id: pool.id)
    assert stored.storage_observation["used_bytes"] == @gib
    refute Map.has_key?(stored.storage_observation, "logical_used_bytes")
    refute Map.has_key?(stored.storage_observation, "compression_ratio")
    assert Budget.available(host, stored, []).disk_bytes == 98 * @gib

    for changed <- [
          Map.delete(snapshot, :storage),
          %{snapshot | storage: nil},
          put_in(snapshot.storage.zpool_guid, "124"),
          put_in(snapshot.storage.dataset_guid, "457"),
          put_in(snapshot.storage.dataset, "tank/other"),
          put_in(snapshot.storage.used_bytes, 0),
          put_in(snapshot.storage.quota_bytes, 99 * @gib),
          put_in(snapshot.storage, Map.put(snapshot.storage, :logical_budget_bytes, 1_000 * @gib))
        ] do
      invalid = %{report | sequence: 3, pools: [hd(report.pools), changed]}
      assert {:error, :invalid_report} = HostReports.ingest(host.id, epoch, invalid)
    end

    assert [%{report_sequence: 2}] = Ledger.read!(Host, id: host.id)
    assert Ledger.read!(StoragePool, id: pool.id) == [stored]
  end

  test "a pool cannot receive another ZFS pool's observations", context do
    changed = Map.put(hd(context.report.pools), :storage, context.snapshot.storage)
    report = %{context.zfs_report | pools: [changed, context.snapshot]}
    assert {:error, :invalid_report} = HostReports.ingest(context.host.id, context.epoch, report)
    assert [%{report_sequence: 1}] = Ledger.read!(Host, id: context.host.id)
  end

  test "enrollment rejects contradictory backend identity and the retired logical budget",
       context do
    base = %{
      host_id: context.host.id,
      name: "invalid",
      backend: :zfs,
      filesystem_id: "zfs:124:457",
      zpool_guid: "124",
      dataset_guid: "457",
      dataset: "other/lilly",
      overhead_bytes: @gib
    }

    for invalid <- [
          Map.put(base, :logical_budget_bytes, 8 * @gib),
          %{base | filesystem_id: "ext4:abc"},
          %{base | backend: :ext4}
        ] do
      assert_raise Ash.Error.Invalid, fn -> Ledger.create!(StoragePool, :enroll, invalid) end
    end
  end

  test "PostgreSQL rejects a non-ZFS backend independently of Ash", context do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Ecto.Adapters.SQL.query(
               Marshall.Repo,
               "UPDATE compute_storage_pools SET backend = 'ext4' WHERE id = $1",
               [Ecto.UUID.dump!(context.zfs.id)]
             )
  end

  test "the retired logical budget column no longer exists", context do
    assert {:error, %Postgrex.Error{postgres: %{code: :undefined_column}}} =
             Ecto.Adapters.SQL.query(
               Marshall.Repo,
               "UPDATE compute_storage_pools SET logical_budget_bytes = 1 WHERE id = $1",
               [Ecto.UUID.dump!(context.zfs.id)]
             )
  end

  test "PostgreSQL rejects a filesystem identity that contradicts the ZFS GUIDs", context do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Ecto.Adapters.SQL.query(
               Marshall.Repo,
               "UPDATE compute_storage_pools SET filesystem_id = 'zfs:9:9' WHERE id = $1",
               [Ecto.UUID.dump!(context.zfs.id)]
             )
  end

  test "one host cannot enroll two schedulable parents on the same zpool", context do
    assert_raise Ash.Error.Invalid, fn ->
      Ledger.create!(StoragePool, :enroll, %{
        host_id: context.host.id,
        name: "alias",
        backend: :zfs,
        filesystem_id: "zfs:123:457",
        zpool_guid: "123",
        dataset_guid: "457",
        dataset: "tank/other",
        overhead_bytes: @gib
      })
    end
  end
end
