defmodule Lilly.Transfer.SnapshotOwnership do
  @moduledoc "Joins local snapshot journals to disk claims and native creation markers."
  alias Lilly.Host.{Command, Pool, ZFSDataset}
  alias Lilly.Transfer.{SnapshotIndex, SnapshotJournal}
  @type failure :: {:error, :snapshot_ownership_unconfirmed}

  # @cc [owner:ghuntley,label:security;capacity] snapshot-expectations-require-three-bindings
  # expectations/1 MUST match every indexed journal to its pool/placement disk claim,
  # and match each native snapshot's local creation nonce before returning GUID
  # expectations. Missing/initializing/corrupt state and uncertain creates MUST fail.
  # Callers hold the pool lock and MUST still run native ZFS accounting/GUID checks
  # and disk ownership verification before granting credit. No transfer index means
  # no expected transfer snapshots; backup expectations require their independent
  # local journal. Neither absence permits adoption by discovered names or tags.
  @spec expectations(Pool.t()) :: {:ok, Lilly.Host.ZFS.snapshots()} | failure()
  def expectations(pool) do
    root = ZFSDataset.ownership_directory(pool)

    with {:ok, entries} <- File.ls(root),
         true <- length(entries) <= 4096 and Enum.all?(entries, &OverallsProtocol.uuid?/1) do
      Enum.reduce_while(entries, {:ok, %{}}, fn placement, {:ok, expected} ->
        with {:ok, snapshots} <-
               placement_expectations(pool, placement, Path.join(root, placement)),
             {:ok, backups} <- Lilly.Host.BackupSnapshot.expectations(pool, placement) do
          {:cont, {:ok, expected |> Map.merge(snapshots) |> Map.merge(backups)}}
        else
          _ -> {:halt, failure()}
        end
      end)
    else
      _ -> failure()
    end
  end

  @doc "Validates a journal's immutable local scope against an existing disk claim."
  @spec claim(Pool.t(), SnapshotJournal.binding()) :: {:ok, map()} | failure()
  def claim(pool, binding) do
    with true <- binding.host_id == pool.host_id and binding.pool_id == pool.id,
         true <- binding.zpool_guid == pool.storage.zpool_guid,
         true <- binding.parent_dataset_guid == pool.storage.dataset_guid,
         {:ok, claim} <- ZFSDataset.snapshot_claim(pool, binding.placement_id),
         true <- binding.dataset_guid == claim.dataset_guid,
         true <- claim.state in ["ready", "deleting", "deleted"] do
      {:ok, claim}
    else
      _ -> failure()
    end
  end

  @doc "An exact local native marker match is necessary but is not complete snapshot ownership."
  @spec marker?(String.t(), String.t()) :: boolean()
  def marker?(snapshot, nonce) do
    case Command.run(:zfs_get, ["-Hp", "-o", "value,source", "lilly:transfer_nonce", snapshot]) do
      {:ok, output} -> output == nonce <> "\tlocal\n"
      _ -> false
    end
  end

  defp placement_expectations(pool, placement, metadata) do
    case SnapshotIndex.current(metadata) do
      {:ok, nil} ->
        {:ok, %{}}

      {:ok, current} ->
        with true <- current.binding.placement_id == placement,
             {:ok, claim} <- claim(pool, current.binding),
             {:ok, suffixes} <- SnapshotJournal.expectations(current.directory, current.binding),
             true <- map_size(suffixes) == 0 or claim.state == "ready" do
          Enum.reduce_while(suffixes, {:ok, %{}}, fn {suffix, identity}, {:ok, expected} ->
            name = ZFSDataset.name(pool, claim.spec) <> "@" <> suffix
            nonce = current.journal["snapshots"][suffix]["nonce"]

            if marker?(name, nonce),
              do: {:cont, {:ok, Map.put(expected, name, identity)}},
              else: {:halt, failure()}
          end)
        else
          _ -> failure()
        end

      _ ->
        failure()
    end
  end

  defp failure, do: {:error, :snapshot_ownership_unconfirmed}
end
