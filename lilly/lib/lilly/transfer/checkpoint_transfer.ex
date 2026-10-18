defmodule Lilly.Transfer.CheckpointTransfer do
  @moduledoc "A separately authorized immutable RAM stream for memory-preserving relocation."
  alias Lilly.Host.{Command, Lock, Pool, PrivateFiles, Privilege, Storage, ZFS}
  alias Lilly.Transfer.{Key, SSH, Stream}
  alias Lilly.VM.{Checkpoint, CheckpointStorage, Spec}
  alias OverallsProtocol.Checkpoint, as: Descriptor
  @type failure :: {:error, :checkpoint_unconfirmed}

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-export-requires-current-owned-memory
  # export/2 requires the live exact permit and pool lock. It MUST match the
  # source's local ready journal and content hashes before deriving the single
  # immutable RAM snapshot. A disk permit without a checkpoint grants no RAM.
  @spec export(Pool.t(), OverallsProtocol.Relocation.descriptor()) ::
          {:ok, Lilly.Transfer.SourceSnapshots.command()} | failure()
  def export(pool, %{checkpoint: descriptor} = transfer) do
    with true <- transfer.source.host_id == pool.host_id and transfer.source.pool_id == pool.id,
         {:ok, spec} <- spec(transfer, :source),
         {:ok, ^descriptor, record} <- Checkpoint.ready(pool, spec, descriptor),
         executable when is_binary(executable) <- System.find_executable("zfs"),
         do:
           {:ok,
            {executable,
             [
               "send",
               "-c",
               CheckpointStorage.name(pool, spec.id, record["slot"]) <> "@lilly-checkpoint"
             ]}},
         else: (_ -> failure())
  end

  def export(_, _), do: failure()

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-receive-intent-before-bytes
  # pull/7 requires current relocation reservations, authenticated distribution
  # and a live pinned transfer key. It MUST hold receive activity ownership and
  # use the same stream lease as the disk. A local nonce and immutable descriptor
  # precede receive; complete bytes must match all content hashes before ready.
  # Partial native state MUST NOT trigger ordinary replay or cold boot.
  @spec pull(Path.t(), Pool.t(), map(), map(), pos_integer(), pos_integer(), pid() | nil) ::
          :ok | failure()
  def pull(root, pool, wire, endpoint, timeout, rate, progress) do
    with {:ok, transfer} <- OverallsProtocol.Relocation.descriptor(wire) do
      if Map.has_key?(transfer, :checkpoint),
        do: pull_memory(root, pool, transfer, endpoint, timeout, rate, progress),
        else: :ok
    else
      _ -> failure()
    end
  end

  defp pull_memory(root, pool, transfer, endpoint, timeout, rate, progress) do
    with {:ok, spec} <- spec(transfer, :destination),
         {:ok, files} <-
           Key.connection(
             root,
             pool.host_id,
             transfer.relocation_id,
             spec.id,
             transfer.source.host_id,
             endpoint
           ) do
      owned(Path.join(Path.dirname(files.stream_dir), "receive"), fn ->
        with {:ok, ^files} <-
               Key.connection(
                 root,
                 pool.host_id,
                 transfer.relocation_id,
                 spec.id,
                 transfer.source.host_id,
                 endpoint
               ),
             result <- Storage.locked(pool, fn -> prepare(pool, spec, transfer) end) do
          case result do
            :ready ->
              :ok

            :complete ->
              finish_locked(files.stream_dir, pool, spec, transfer)

            {:receive, consumer} ->
              request = %{
                host_id: pool.host_id,
                relocation_id: transfer.relocation_id,
                placement_id: spec.id,
                source_host_id: transfer.source.host_id
              }

              with {:ok, {:ssh, producer}} <- SSH.command(endpoint, request, files),
                   :ok <-
                     Stream.run(
                       files.stream_dir,
                       {:ssh, %{producer | verb: :checkpoint}},
                       consumer,
                       timeout,
                       rate,
                       progress
                     ),
                   do: finish_locked(files.stream_dir, pool, spec, transfer)

            _ ->
              failure()
          end
        else
          _ -> failure()
        end
      end)
    else
      _ -> failure()
    end
  end

  defp prepare(pool, spec, transfer) do
    with true <-
           transfer.destination.host_id == pool.host_id and
             transfer.destination.pool_id == pool.id,
         :ok <- PrivateFiles.directory(Path.join(pool.path, ".lilly-checkpoints")),
         :ok <- PrivateFiles.directory(Path.join([pool.path, ".lilly-checkpoints", spec.id])),
         {:ok, record} <- receive_journal(pool, spec, transfer) do
      case record["phase"] do
        "ready" ->
          with {:ok, _, _} <- Checkpoint.ready(pool, spec, transfer.checkpoint),
               :ok <- CheckpointStorage.prepare_unused(pool, spec),
               do: :ready

        "receiving" ->
          dataset = CheckpointStorage.name(pool, spec.id, "a")

          case Command.run(:zfs_list, ["-Hp", "-o", "name", dataset]) do
            {:error, :command_failed} ->
              with true <- is_nil(record["slots"]["a"]["dataset_guid"]),
                   {:error, :enoent} <- File.lstat(CheckpointStorage.path(pool, spec.id, "a")) do
                {:receive,
                 {:checkpoint_receive,
                  %{
                    dataset: pool.storage.dataset,
                    pool: pool.path,
                    placement: spec.id,
                    host: pool.host_id,
                    pool_id: pool.id,
                    nonce: record["slots"]["a"]["nonce"],
                    memory_bytes: spec.memory_bytes
                  }}}
              end

            {:ok, output} when output == dataset <> "\n" ->
              :complete

            _ ->
              failure()
          end

        _ ->
          failure()
      end
    else
      _ -> failure()
    end
  end

  defp receive_journal(pool, spec, transfer) do
    wire = OverallsProtocol.Relocation.encode_descriptor(transfer)

    case Checkpoint.read(pool, spec.id) do
      {:ok, nil} ->
        value = Checkpoint.initial(pool, spec)

        with :ok <- Checkpoint.write(pool, spec.id, value),
             do: receive_journal(pool, spec, transfer)

      {:ok, %{"phase" => "empty", "slots" => slots} = value} when map_size(slots) == 0 ->
        leaf = %{
          "state" => "creating",
          "nonce" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
          "dataset_guid" => nil,
          "snapshot_guid" => nil,
          "checkpoint_id" => transfer.checkpoint.id
        }

        next = %{
          value
          | "phase" => "receiving",
            "slot" => "a",
            "checkpoint_id" => transfer.checkpoint.id,
            "descriptor" => Descriptor.encode(transfer.checkpoint),
            "relocation" => wire,
            "slots" => %{"a" => leaf}
        }

        with :ok <- Checkpoint.write(pool, spec.id, next), do: {:ok, next}

      {:ok, %{"relocation" => ^wire} = value} ->
        {:ok, value}

      _ ->
        failure()
    end
  end

  defp finish_locked(stream, pool, spec, transfer) do
    owned(stream, fn -> Storage.locked(pool, fn -> finish(pool, spec, transfer) end, 2000) end)
  end

  defp finish(pool, spec, transfer) do
    with {:ok, %{"phase" => "receiving"} = record} <- receive_journal(pool, spec, transfer),
         leaf = record["slots"]["a"],
         dataset = CheckpointStorage.name(pool, spec.id, "a"),
         {:ok, guid} <- received_native(pool, spec, leaf, transfer.checkpoint),
         leaf = %{
           leaf
           | "dataset_guid" => guid,
             "snapshot_guid" => transfer.checkpoint.snapshot_guid
         },
         bound = put_in(record, ["slots", "a"], leaf),
         :ok <- Checkpoint.write(pool, spec.id, bound),
         {:ok, _} <-
           Command.run(:zfs_set, [
             "lilly:transfer_nonce=" <> transfer.checkpoint.id,
             dataset <> "@lilly-checkpoint"
           ]),
         {:ok, _} <- Command.run(:zfs_set, ["canmount=on", dataset]),
         :ok <- mount(dataset, CheckpointStorage.path(pool, spec.id, "a")),
         :ok <- normalize_private_files(pool, spec, dataset),
         {:ok, bytes} <-
           PrivateFiles.read_secret(
             Path.join(CheckpointStorage.path(pool, spec.id, "a"), "manifest.json")
           ),
         true <- Checkpoint.digest(bytes) == transfer.checkpoint.manifest_sha256,
         {:ok, manifest} <- JSON.decode(bytes),
         true <- Checkpoint.valid_manifest?(manifest) and manifest["id"] == transfer.checkpoint.id,
         leaf = %{leaf | "state" => "sealed"},
         complete = %{bound | "manifest" => manifest, "slots" => %{"a" => leaf}},
         :ok <- CheckpointStorage.verify(pool, spec, complete),
         :ok <- Checkpoint.write(pool, spec.id, %{complete | "phase" => "ready"}),
         :ok <- CheckpointStorage.prepare_unused(pool, spec),
         do: :ok,
         else: (_ -> failure())
  end

  defp received_native(pool, spec, leaf, descriptor) do
    dataset = CheckpointStorage.name(pool, spec.id, "a")
    snapshot = dataset <> "@lilly-checkpoint"

    with true <- ZFS.staging_identity?(Pool.zfs_identity(pool)),
         {:ok, output} <-
           Command.run(:zfs_list, [
             "-Hp",
             "-t",
             "all",
             "-o",
             Enum.join(ZFS.properties(), ","),
             "-r",
             dataset
           ]),
         {:ok, rows} <- ZFS.parse_datasets(output),
         true <- Enum.sort(Map.keys(rows)) == Enum.sort([dataset, snapshot]),
         row when is_map(row) <- rows[dataset],
         true <-
           (row["readonly"] == "on" or
              (row["readonly"] == "off" and leaf["dataset_guid"] == row["guid"] and
                 leaf["snapshot_guid"] == descriptor.snapshot_guid)) and
             row["canmount"] in ["noauto", "on"] and
             row["mounted"] in ["no", "yes"],
         true <-
           ZFS.checkpoint_row?(
             {dataset, row |> Map.put("mounted", "yes") |> Map.put("canmount", "on")},
             Pool.zfs_identity(pool)
           ),
         true <- row["quota"] == OverallsProtocol.VMShape.checkpoint_bytes(spec.memory_bytes),
         true <-
           rows[snapshot]["type"] == "snapshot" and
             rows[snapshot]["guid"] == descriptor.snapshot_guid,
         true <- is_nil(leaf["dataset_guid"]) or leaf["dataset_guid"] == row["guid"],
         {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool), dataset),
         true <- Enum.sort(Map.keys(owners)) == Enum.sort(Map.keys(rows)),
         true <-
           Enum.all?(owners, fn {name, owner} ->
             owner["guid"] == rows[name]["guid"] and
               Map.drop(owner, ["guid"]) == %{
                 "host" => pool.host_id,
                 "pool" => pool.id,
                 "vm" => spec.id,
                 "nonce" => leaf["nonce"]
               }
           end),
         {:ok, mounts} <- ZFS.mounts(),
         true <-
           CheckpointStorage.mounts_valid?(
             pool,
             spec.id,
             "a",
             mounts,
             if(row["mounted"] == "yes", do: :mounted, else: :unmounted),
             false
           ),
         do: {:ok, row["guid"]},
         else: (_ -> failure())
  end

  # @cc [owner:ghuntley,label:security;recovery] received-checkpoint-private-ownership-is-local
  # Only the inert, GUID-bound receiving dataset may become writable to
  # normalize the fixed private directory/file owners. No content is written.
  # Exact singleton regular files, private modes, a flush and readonly=on MUST
  # precede hash verification and ready authority. Source service UIDs need not
  # equal the destination UID; interruption remains receiving and repeatable.
  defp normalize_private_files(pool, spec, dataset) do
    root = CheckpointStorage.path(pool, spec.id, "a")
    out = Path.join(root, "output")
    uid = Privilege.service_uid()

    with {:ok, _} <- Command.run(:zfs_set, ["readonly=off", dataset]),
         :ok <- Privilege.claim_directory(root),
         {:ok, entries} <- File.ls(root),
         true <- Enum.sort(entries) == ["manifest.json", "output"],
         {:ok, %File.Stat{type: :directory}} <- File.lstat(out),
         {:ok, _} <- Command.run(:chown, ["--no-dereference", "#{uid}:#{uid}", "--", out]),
         :ok <- Privilege.chmod(out, 0o700),
         {:ok, entries} <- File.ls(out),
         true <- Enum.sort(entries) == ["memory", "state"],
         :ok <- normalize_file(Path.join(root, "manifest.json"), uid, 0o600),
         :ok <- normalize_file(Path.join(out, "memory"), uid, 0o444),
         :ok <- normalize_file(Path.join(out, "state"), uid, 0o444),
         {:ok, _} <- Command.run(:sync, ["--", root], 14_400_000),
         {:ok, _} <- Command.run(:zfs_set, ["readonly=on", dataset]),
         do: :ok,
         else: (_ -> failure())
  end

  defp normalize_file(path, uid, mode) do
    with {:ok, %File.Stat{type: :regular, links: 1}} <- File.lstat(path),
         {:ok, _} <- Command.run(:chown, ["--no-dereference", "#{uid}:#{uid}", "--", path]),
         do: Privilege.chmod(path, mode)
  end

  @doc "Verify RAM adoption alongside the received portable disk, without loading it."
  @spec adopted(Pool.t(), Spec.t(), OverallsProtocol.Relocation.descriptor()) :: :ok | failure()
  def adopted(pool, spec, %{checkpoint: descriptor}) do
    with {:ok, ^descriptor, _} <- Checkpoint.ready(pool, spec, descriptor),
         do: :ok,
         else: (_ -> failure())
  end

  def adopted(_, _, _), do: :ok

  defp spec(transfer, endpoint) do
    transfer.workload
    |> Map.drop([:architecture])
    |> Map.merge(%{id: transfer[endpoint].placement_id, pool_id: transfer[endpoint].pool_id})
    |> Spec.new()
  end

  defp mount(dataset, path) do
    case Lilly.Host.MountTable.at(path) do
      {:ok, %{"source" => ^dataset, "target" => ^path, "fstype" => "zfs"}} -> :ok
      _ -> with {:ok, _} <- Command.run(:zfs_mount, [dataset]), do: :ok
    end
  end

  defp owned(directory, fun) do
    with :ok <- PrivateFiles.directory(directory), {:ok, lock} <- Lock.acquire(directory) do
      try do
        result = fun.()
        with :ok <- Lock.release(lock), do: result
      after
        if Lock.held?(lock), do: Lock.release(lock)
      end
    else
      _ -> failure()
    end
  end

  defp failure, do: {:error, :checkpoint_unconfirmed}
end
