defmodule Lilly.Host.RestoredAuthorityTest do
  @moduledoc """
  Restored `.lilly-zfs` ownership metadata is historical evidence, never live
  authority (ADR-0070): after disk replacement the live pool carries new native
  identity, and restored owner/claim/backup journals MUST be refused by the
  journal-read and claim layers without any automatic reactivation or rewrite.
  The `Pool.new`/`ZFSDataset.bind` comparison against a real replacement pool
  remains native machine evidence; this generated property pins the file-level
  refusal semantics both layers then enforce once the identities diverge.
  """
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  import Bitwise
  alias Lilly.Host.{BackupSnapshot, Lock, Pool, ZFSDataset}
  alias Lilly.Lifecycle.Journal
  alias Lilly.VM.Spec
  @moduletag :tmp_dir

  @divergent [:zpool_guid, :dataset_guid, :host_id, :pool_id]
  @claim_guid "5502938471002938"

  defp identity(path) do
    %{
      path: path,
      host_id: Lilly.UUID.generate(),
      pool_id: Lilly.UUID.generate(),
      dataset: "tank/lilly",
      zpool_guid: "8473663987254177",
      dataset_guid: "1294829134928374"
    }
  end

  defp pool(fields) do
    %Pool{
      id: fields.pool_id,
      path: fields.path,
      filesystem_id: "zfs:1:2",
      host_id: fields.host_id,
      storage: %{
        backend: :zfs,
        dataset: fields.dataset,
        zpool_guid: fields.zpool_guid,
        dataset_guid: fields.dataset_guid
      }
    }
  end

  defp placement_spec(placement, fields) do
    {:ok, network} = Lilly.Network.Guest.new(Lilly.UUID.generate(), :customer, 2)

    %Spec{
      id: placement,
      image_id: "sha256:" <> String.duplicate("a", 64),
      pool_id: fields.pool_id,
      network: network,
      vcpu: 1,
      memory_bytes: 1_073_741_824,
      disk_bytes: 4_294_967_296
    }
  end

  defp replacement(previous) do
    if String.contains?(previous, "-") do
      Lilly.UUID.generate()
    else
      Integer.to_string(String.to_integer(previous) + 9_999_937)
    end
  end

  defp diverge(fields, changed) do
    Enum.reduce(changed, fields, fn field, acc ->
      Map.put(acc, field, replacement(Map.fetch!(acc, field)))
    end)
  end

  # Mirrors a restic restore of the historical ownership tree: plain private
  # files at identical relative paths, bytes exactly as the failed host wrote.
  # Returns the planted byte inventory; later reads must never rewrite it.
  defp plant_restored_metadata(pool, guest, placement) do
    base = Path.join(pool.path, ".lilly-zfs")
    active = Path.join([base, "active", placement])
    File.mkdir_p!(active)
    File.chmod!(base, 0o700)
    File.chmod!(Path.join(base, "active"), 0o700)
    File.chmod!(active, 0o700)
    owner_path = Path.join(base, "owner.json")
    claim_path = Path.join(active, "claim.json")
    journal_path = Path.join(active, "backup.json")

    File.write!(
      owner_path,
      JSON.encode!(%{
        "host_id" => pool.host_id,
        "pool_id" => pool.id,
        "pool_path" => pool.path,
        "storage" => OverallsProtocol.Storage.encode(pool.storage)
      })
    )

    File.chmod!(owner_path, 0o600)
    # Writes carry the exact production journal discipline, then the lock is
    # released so reads contend with the restored bytes only.
    {:ok, lock} = Lock.acquire(Path.join(pool.path, "lock-hold"))

    claim = %{
      "version" => 1,
      "binding" => %{
        "host_id" => pool.host_id,
        "pool_id" => pool.id,
        "pool_path" => pool.path,
        "storage" => OverallsProtocol.Storage.encode(pool.storage),
        "spec" => Spec.encode(guest)
      },
      "nonce" => String.duplicate("cd", 16),
      "dataset_guid" => nil,
      "state" => "creating"
    }

    backup = %{
      "version" => 1,
      "host_id" => pool.host_id,
      "pool_id" => pool.id,
      "zpool_guid" => pool.storage.zpool_guid,
      "parent_dataset_guid" => pool.storage.dataset_guid,
      "placement_id" => placement,
      "dataset_guid" => @claim_guid,
      "run_id" => Lilly.UUID.generate(),
      "nonce" => String.duplicate("ef", 32),
      "snapshot_guid" => "4829102938475610293",
      "phase" => "ready"
    }

    try do
      assert :ok = Journal.write(Lilly.Lifecycle.Dataset, active, "claim.json", claim)
      ready = %{claim | "dataset_guid" => @claim_guid, "state" => "bound"}
      assert :ok = Journal.write(Lilly.Lifecycle.Dataset, active, "claim.json", ready)

      assert :ok =
               Journal.write(Lilly.Lifecycle.Dataset, active, "claim.json", %{
                 ready
                 | "state" => "ready"
               })

      assert :ok =
               Journal.write(Lilly.Lifecycle.BackupSnapshot, active, "backup.json", %{
                 backup
                 | "snapshot_guid" => nil,
                   "phase" => "creating"
               })

      assert :ok = Journal.write(Lilly.Lifecycle.BackupSnapshot, active, "backup.json", backup)
    after
      :ok = Lock.release(lock)
    end

    %{
      "owner.json" => File.read!(owner_path),
      "claim.json" => File.read!(claim_path),
      "backup.json" => File.read!(journal_path)
    }
  end

  test "restored ownership metadata with divergent live identity is refused, never rewritten",
       %{tmp_dir: root} do
    # All fifteen nonempty divergent identity-field combinations, enumerated.
    for mask <- 1..15 do
      changed =
        @divergent
        |> Enum.with_index()
        |> Enum.filter(fn {_, bit} -> (mask >>> bit &&& 1) == 1 end)
        |> Enum.map(&elem(&1, 0))

      path = Path.join(root, "pool-#{mask}")
      File.mkdir_p!(path)
      File.chmod!(path, 0o700)
      fields = identity(path)
      placement = Lilly.UUID.generate()
      historical = pool(fields)
      guest = placement_spec(placement, fields)
      before = plant_restored_metadata(historical, guest, placement)
      live = pool(diverge(fields, changed))

      # Fixture sanity: the planted tree is valid under the identity that wrote
      # it. Acceptance here is not authority evidence for the live pool.
      assert {:ok, %{state: "ready", dataset_guid: @claim_guid}} =
               ZFSDataset.snapshot_claim(historical, placement)

      assert {:ok, %{"phase" => "ready"}} = BackupSnapshot.read(historical, placement),
             "divergence #{inspect(changed)} broke the historical control"

      # The claim-read, backup-journal and capacity-expectation layers over the
      # live pool refuse the restored records for every divergent combination.
      assert {:error, :zfs_snapshot_claim_unconfirmed} =
               ZFSDataset.snapshot_claim(live, placement),
             "snapshot_claim accepted stale #{inspect(changed)}"

      assert {:error, :backup_snapshot_unconfirmed} =
               BackupSnapshot.read(live, placement),
             "backup journal accepted stale #{inspect(changed)}"

      assert {:error, :backup_snapshot_unconfirmed} =
               BackupSnapshot.expectations(live, placement),
             "capacity expectations accepted stale #{inspect(changed)}"

      # No automatic reactivation: restored bytes are never rewritten in place.
      assert before == %{
               "owner.json" => File.read!(Path.join([path, ".lilly-zfs", "owner.json"])),
               "claim.json" =>
                 File.read!(Path.join([path, ".lilly-zfs", "active", placement, "claim.json"])),
               "backup.json" =>
                 File.read!(Path.join([path, ".lilly-zfs", "active", placement, "backup.json"]))
             },
             "restored metadata was rewritten for #{inspect(changed)}"
    end
  end

  test "matching live identity accepts the restored ownership tree", %{tmp_dir: root} do
    path = Path.join(root, "pool")
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    fields = identity(path)
    placement = Lilly.UUID.generate()
    live = pool(fields)
    guest = placement_spec(placement, fields)
    plant_restored_metadata(live, guest, placement)

    assert {:ok, %{state: "ready", dataset_guid: @claim_guid, spec: loaded}} =
             ZFSDataset.snapshot_claim(live, placement)

    assert loaded.id == placement

    assert {:ok, %{"phase" => "ready", "dataset_guid" => @claim_guid}} =
             BackupSnapshot.read(live, placement)
  end
end
