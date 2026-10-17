defmodule Lilly.Host.BackupSnapshot do
  @moduledoc "Host-local backup snapshot intent, exact ownership, and resumable cleanup."
  require Lilly.Events
  alias Lilly.Host.{Command, Lock, Pool, ZFS, ZFSDataset}
  alias Lilly.Lifecycle.{BackupHistory, Journal}
  alias Lilly.Transfer.SnapshotOwnership
  alias Lilly.VM.Spec
  @suffix "lilly-backup"
  @type failure :: {:error, :backup_snapshot_unconfirmed}
  @type journal :: %{required(String.t()) => String.t() | pos_integer() | nil}

  @spec read(Pool.t(), String.t()) :: {:ok, journal() | nil} | failure()
  def read(pool, placement) do
    path = Path.join([ZFSDataset.ownership_directory(pool), placement, "backup.json"])

    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, nil}

      {:ok, _} ->
        with true <- OverallsProtocol.uuid?(placement),
             {:ok, %{payload: value}} <-
               Journal.load(Lilly.Lifecycle.BackupSnapshot, Path.dirname(path), "backup.json"),
             true <- valid?(value, pool, placement),
             do: {:ok, value},
             else: (_ -> failure())

      _ ->
        failure()
    end
  end

  # @cc [owner:ghuntley,label:security;capacity] backup-expectation-requires-native-identity
  # Only a ready journal bound to this host, pool, disk claim and local creation
  # nonce may authorize a backup snapshot in capacity observations. Uncertain
  # creation/cleanup MUST withhold credit. Names alone never establish ownership.
  @spec expectations(Pool.t(), String.t()) :: {:ok, ZFS.snapshots()} | failure()
  def expectations(pool, placement) do
    case read(pool, placement) do
      {:ok, nil} ->
        {:ok, %{}}

      {:ok, %{"phase" => "cleaned"}} ->
        {:ok, %{}}

      {:ok, %{"phase" => "ready"} = journal} ->
        with {:ok, claim} <- bound_claim(pool, placement, journal),
             true <- claim.state in ["ready", "deleting"],
             true <- marker?(name(pool, placement), journal["nonce"]),
             do:
               {:ok,
                %{
                  name(pool, placement) => %{
                    dataset_guid: journal["dataset_guid"],
                    snapshot_guid: journal["snapshot_guid"]
                  }
                }},
             else: (_ -> failure())

      _ ->
        failure()
    end
  end

  # @cc [owner:ghuntley,label:recovery] backup-snapshot-intent-before-native-create
  # create/3 requires the pool mutation lock and a verified ready disk. It MUST
  # persist nonce-bound creation intent before ZFS creation, reject active prior
  # backups or foreign snapshots, and publish ready only after GUID verification.
  @spec create(Pool.t(), Spec.t(), String.t()) :: {:ok, journal()} | failure()
  def create(pool, spec, run_id) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         true <- OverallsProtocol.uuid?(run_id),
         :ok <- ZFSDataset.bind(pool),
         {:ok, claim} <- ZFSDataset.snapshot_source(pool, spec),
         {:ok, previous} <- read(pool, spec.id),
         true <- is_nil(previous) or previous["phase"] == "cleaned",
         {:ok, expected} <- SnapshotOwnership.expectations(pool),
         selected =
           Map.filter(expected, fn {snapshot, _} ->
             String.starts_with?(snapshot, ZFSDataset.name(pool, spec) <> "@")
           end),
         :ok <-
           ZFS.transfer_child(
             Pool.zfs_identity(pool),
             ZFSDataset.name(pool, spec),
             claim.dataset_guid,
             selected
           ),
         :ok <-
           BackupHistory.prepare(
             Path.join(ZFSDataset.ownership_directory(pool), spec.id),
             previous
           ),
         journal = %{
           "version" => 1,
           "host_id" => pool.host_id,
           "pool_id" => pool.id,
           "zpool_guid" => pool.storage.zpool_guid,
           "parent_dataset_guid" => pool.storage.dataset_guid,
           "placement_id" => spec.id,
           "dataset_guid" => claim.dataset_guid,
           "run_id" => run_id,
           "nonce" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
           "snapshot_guid" => nil,
           "phase" => "creating"
         },
         :ok <- save(pool, spec.id, journal),
         {:ok, _} <-
           Command.run(
             :zfs_snapshot,
             ["-o", "lilly:backup_nonce=" <> journal["nonce"], name(pool, spec.id)],
             30_000
           ),
         {:ok, guid} <- native_guid(pool, spec.id, journal),
         journal = %{journal | "phase" => "ready", "snapshot_guid" => guid},
         :ok <- save(pool, spec.id, journal),
         :ok <-
           ZFS.transfer_child(
             Pool.zfs_identity(pool),
             ZFSDataset.name(pool, spec),
             claim.dataset_guid,
             Map.put(selected, name(pool, spec.id), %{
               dataset_guid: claim.dataset_guid,
               snapshot_guid: guid
             })
           ) do
      Lilly.Events.emit("lilly.backup_snapshot_created", placement_id: spec.id)
      {:ok, journal}
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:recovery;security] backup-cleanup-exact-intent
  # cleanup/3 requires the pool lock and stopped backup readers. It MUST only
  # destroy the requested run's nonce/GUID-bound snapshot, recover uncertain
  # creation for cleanup only, and confirm absence before writing cleaned.
  # Cleanup MUST remain possible when lifecycle deletion has marked the disk
  # deleting. It MUST NOT delete the disk or alter execution intent.
  @spec cleanup(Pool.t(), String.t(), String.t()) :: :ok | failure()
  def cleanup(pool, placement, run_id) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         {:ok, journal} when is_map(journal) <- read(pool, placement),
         true <- journal["run_id"] == run_id do
      if journal["phase"] == "cleaned" do
        :ok
      else
        with {:ok, _} <- bound_claim(pool, placement, journal),
             journal = %{journal | "phase" => "cleaning"},
             :ok <- save(pool, placement, journal),
             {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)),
             :ok <- destroy(pool, placement, journal, owners[name(pool, placement)]),
             {:ok, remaining} <- ZFS.owners(Pool.zfs_identity(pool)),
             false <- Map.has_key?(remaining, name(pool, placement)),
             :ok <- save(pool, placement, %{journal | "phase" => "cleaned"}),
             do: :ok,
             else: (_ -> failure())
      end
    else
      _ -> failure()
    end
  end

  defp destroy(_, _, _, nil), do: :ok

  defp destroy(pool, placement, journal, _) do
    with {:ok, _} <- native_guid(pool, placement, journal),
         {:ok, _} <- Command.run(:zfs_destroy, [name(pool, placement)], 30_000),
         do: :ok,
         else: (_ -> failure())
  end

  defp native_guid(pool, placement, journal) do
    with {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)),
         %{"guid" => guid, "host" => host, "pool" => pool_id, "vm" => vm} <-
           owners[name(pool, placement)],
         true <- host == pool.host_id and pool_id == pool.id and vm == placement,
         true <- is_nil(journal["snapshot_guid"]) or journal["snapshot_guid"] == guid,
         true <- marker?(name(pool, placement), journal["nonce"]),
         do: {:ok, guid},
         else: (_ -> failure())
  end

  defp bound_claim(pool, placement, journal) do
    with {:ok, claim} <- ZFSDataset.snapshot_claim(pool, placement),
         true <- claim.dataset_guid == journal["dataset_guid"],
         {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)),
         %{"guid" => guid, "host" => host, "pool" => pool_id, "vm" => vm} <-
           owners[ZFSDataset.name(pool, claim.spec)],
         true <-
           guid == claim.dataset_guid and host == pool.host_id and pool_id == pool.id and
             vm == placement,
         do: {:ok, claim},
         else: (_ -> failure())
  end

  defp marker?(snapshot, nonce) do
    case Command.run(:zfs_get, ["-Hp", "-o", "value,source", "lilly:backup_nonce", snapshot]) do
      {:ok, output} -> output == nonce <> "\tlocal\n"
      _ -> false
    end
  end

  defp valid?(value, pool, placement) when is_map(value) do
    Enum.sort(Map.keys(value)) ==
      Enum.sort(
        ~w(version host_id pool_id zpool_guid parent_dataset_guid placement_id dataset_guid run_id nonce snapshot_guid phase)
      ) and
      value["version"] == 1 and value["host_id"] == pool.host_id and value["pool_id"] == pool.id and
      value["zpool_guid"] == pool.storage.zpool_guid and
      value["parent_dataset_guid"] == pool.storage.dataset_guid and
      value["placement_id"] == placement and OverallsProtocol.uuid?(value["run_id"]) and
      is_binary(value["nonce"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value["nonce"]) and
      guid?(value["dataset_guid"]) and
      (is_nil(value["snapshot_guid"]) or guid?(value["snapshot_guid"])) and
      value["phase"] in ~w(creating ready cleaning cleaned) and
      (value["phase"] != "ready" or guid?(value["snapshot_guid"]))
  end

  defp guid?(value), do: is_binary(value) and Regex.match?(~r/\A[1-9][0-9]{0,19}\z/, value)

  defp save(pool, placement, value),
    do:
      Journal.write(
        Lilly.Lifecycle.BackupSnapshot,
        Path.join(ZFSDataset.ownership_directory(pool), placement),
        "backup.json",
        value
      )

  @spec name(Pool.t(), String.t()) :: String.t()
  def name(pool, placement), do: pool.storage.dataset <> "/vm-" <> placement <> "@" <> @suffix
  defp failure, do: {:error, :backup_snapshot_unconfirmed}
end
