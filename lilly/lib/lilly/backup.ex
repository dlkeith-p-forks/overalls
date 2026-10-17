defmodule Lilly.Backup do
  @moduledoc "Local operator backup effects, independent of control-plane availability."
  require Lilly.Events
  alias Lilly.Host.{BackupSnapshot, Command, Lock, Pool, PrivateFiles, Storage, ZFSDataset}
  alias Lilly.VM.{Boot, Flush, Intent, Jail, Spec}

  # @cc [owner:ghuntley,label:security;recovery] backup-local-operator-boundary
  # main/0 MUST run only as root, accept closed operation names and private
  # requests, and derive all native paths from trusted configuration and local
  # ownership claims. It MUST never need a Marshall connection or emit raw errors.
  # Start Ash dependencies for local journals, never the Lilly control runtime.
  @spec main() :: no_return()
  def main do
    result =
      try do
        with {:ok, %File.Stat{uid: 0}} <- Lilly.Host.Privilege.stat("/proc/self"),
             {:ok, _} <- Application.ensure_all_started(:ash),
             {:ok, body} <- File.read(System.fetch_env!("OVERALLS_BACKUP_CONFIG")),
             {:ok, config} <- JSON.decode(body),
             {:ok, request} <-
               PrivateFiles.read_secret(System.fetch_env!("OVERALLS_BACKUP_REQUEST")),
             {:ok, value} when is_map(value) <- JSON.decode(request),
             {:ok, pools} <- pools(config),
             do: execute(System.fetch_env!("OVERALLS_BACKUP_OPERATION"), config, pools, value),
             else: (_ -> {:error, :backup_unconfirmed})
      rescue
        _ -> {:error, :backup_unconfirmed}
      catch
        _, _ -> {:error, :backup_unconfirmed}
      end

    case result do
      {:ok, value} ->
        backup_completed(value)
        IO.puts(JSON.encode!(value))
        System.halt(0)

      _ ->
        System.halt(1)
    end
  end

  # @cc [owner:ghuntley,label:recovery;observability] backup-completion-correlated
  # The completion event MUST carry at most the captured placement identifier;
  # backup paths, snapshots, specs and request payloads MUST NOT be logged.
  defp backup_completed(%{id: id}) do
    if OverallsProtocol.uuid?(id) do
      Lilly.Events.emit("lilly.backup_completed", placement_id: id)
    else
      Lilly.Events.emit("lilly.backup_completed", [])
    end
  end

  defp backup_completed(_), do: Lilly.Events.emit("lilly.backup_completed", [])

  defp pools(config) do
    Enum.reduce_while(config["pools"], {:ok, []}, fn value, {:ok, acc} ->
      case Pool.new(value["id"], value["path"], value["filesystem_id"],
             storage: value["storage"],
             host_id: config["host_id"]
           ) do
        {:ok, pool} -> {:cont, {:ok, acc ++ [pool]}}
        _ -> {:halt, {:error, :backup_pool_unconfirmed}}
      end
    end)
  end

  defp execute("inventory", _config, pools, request) when map_size(request) == 0 do
    Enum.reduce_while(pools, {:ok, []}, fn pool, {:ok, acc} ->
      case Storage.locked(pool, fn -> inventory(pool) end) do
        {:ok, guests} -> {:cont, {:ok, acc ++ guests}}
        _ -> {:halt, {:error, :backup_inventory_unconfirmed}}
      end
    end)
    |> case do
      {:ok, guests} -> {:ok, %{guests: guests}}
      error -> error
    end
  end

  defp execute("pressure", config, pools, %{"pool_id" => pool_id} = request)
       when map_size(request) == 1 do
    with %Pool{} = pool <- Enum.find(pools, &(&1.id == pool_id)),
         {:ok, usage} <- Storage.locked(pool, fn -> ZFSDataset.observe(pool) end),
         do: {:ok, %{available: usage.free_bytes >= config["minimum_free_bytes"]}},
         else: (_ -> {:error, :backup_headroom_unavailable})
  end

  defp execute(
         "capture",
         config,
         pools,
         %{"id" => id, "pool_id" => pool_id, "run_id" => run_id} = request
       )
       when map_size(request) == 3 do
    with true <- OverallsProtocol.uuid?(id) and OverallsProtocol.uuid?(run_id),
         %Pool{} = pool <- Enum.find(pools, &(&1.id == pool_id)),
         directory = Path.join(config["vm_state_directory"], id),
         {:ok, port} <- Lock.acquire(Path.join(directory, "lock")) do
      try do
        with {:ok, claim} <- ZFSDataset.snapshot_claim(pool, id),
             flush = flush(directory, pool, claim.spec),
             {:ok, journal} <-
               Storage.locked(pool, fn ->
                 with :ok <- ZFSDataset.bind(pool),
                      {:ok, snapshot} <- Lilly.Host.PoolSnapshot.read(pool),
                      {:ok, _} <- ZFSDataset.allocations(pool, snapshot),
                      true <-
                        snapshot.observation.free_bytes >= config["minimum_free_bytes"],
                      do: BackupSnapshot.create(pool, claim.spec, run_id),
                      else: (_ -> {:error, :backup_headroom_unavailable})
               end) do
          mount = mount_path(pool, id)

          with :ok <- Storage.locked(pool, fn -> mount_snapshot(pool, id, mount) end) do
            {:ok,
             %{
               id: id,
               pool_id: pool.id,
               run_id: run_id,
               flush: flush,
               captured_at: System.system_time(:second),
               snapshot: BackupSnapshot.name(pool, id),
               snapshot_guid: journal["snapshot_guid"],
               dataset_guid: claim.dataset_guid,
               spec: Spec.encode(claim.spec),
               mount: mount,
               paths: Enum.map(Spec.drives(claim.spec), &Path.join(mount, &1.name))
             }}
          end
        end
      after
        Lock.release(port)
      end
    else
      _ -> {:error, :backup_capture_unconfirmed}
    end
  end

  defp execute("release", _config, pools, %{"id" => id, "pool_id" => pool_id, "run_id" => run_id}) do
    with true <- OverallsProtocol.uuid?(id) and OverallsProtocol.uuid?(run_id),
         %Pool{} = pool <- Enum.find(pools, &(&1.id == pool_id)),
         :ok <- Storage.locked(pool, fn -> release(pool, id, run_id) end),
         do: {:ok, %{pending: 0}},
         else: (_ -> {:error, :backup_cleanup_unconfirmed})
  end

  defp execute("cleanup", _config, pools, request) when map_size(request) == 0 do
    pending =
      Enum.reduce(pools, 0, fn pool, count ->
        case Storage.locked(pool, fn ->
               with {:ok, entries} <- entries(pool) do
                 Enum.reduce(entries, 0, fn id, pending ->
                   case BackupSnapshot.read(pool, id) do
                     {:ok, nil} ->
                       pending

                     {:ok, %{"phase" => "cleaned"}} ->
                       pending

                     {:ok, journal} ->
                       if release(pool, id, journal["run_id"]) == :ok,
                         do: pending,
                         else: pending + 1

                     _ ->
                       pending + 1
                   end
                 end)
               end
             end) do
          result when is_integer(result) -> count + result
          _ -> count + 1
        end
      end)

    {:ok, %{pending: pending}}
  end

  # @cc [owner:ghuntley,label:recovery] backup-pool-metadata-under-lock
  # Copy ownership and import/tombstone journals under the pool mutation lock.
  # Parent snapshots MUST NOT bypass Lilly's strict native snapshot policy.
  # Only a fixed private destination derived from the configured pool is writable.
  defp execute("metadata", _config, pools, request) when map_size(request) == 0 do
    Enum.reduce_while(pools, {:ok, []}, fn pool, {:ok, paths} ->
      destination = Path.join(["/run/overalls-backups", "pools", pool.id])

      case Storage.locked(pool, fn ->
             with :ok <- ZFSDataset.bind(pool),
                  :ok <- PrivateFiles.directory("/run/overalls-backups"),
                  :ok <- PrivateFiles.directory("/run/overalls-backups/pools"),
                  :ok <- Lilly.Host.Privilege.remove_tree(destination),
                  {:ok, _} <-
                    Command.run(
                      :cp,
                      [
                        "--archive",
                        "--no-target-directory",
                        "--",
                        Path.join(pool.path, ".lilly-zfs"),
                        destination
                      ],
                      30_000
                    ),
                  do: :ok
           end) do
        :ok -> {:cont, {:ok, paths ++ [destination]}}
        _ -> {:halt, {:error, :backup_metadata_unconfirmed}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, %{paths: paths}}
      error -> error
    end
  end

  defp execute(_, _, _, _), do: {:error, :invalid_backup_operation}

  defp inventory(pool) do
    with :ok <- ZFSDataset.bind(pool), {:ok, entries} <- entries(pool) do
      Enum.reduce_while(entries, {:ok, []}, fn id, {:ok, acc} ->
        case ZFSDataset.snapshot_claim(pool, id) do
          {:ok, %{state: "ready"}} -> {:cont, {:ok, acc ++ [%{id: id, pool_id: pool.id}]}}
          # Persistent but unfinished allocations must not silently disappear
          # from a full-node recovery inventory.
          _ -> {:halt, {:error, :backup_inventory_unconfirmed}}
        end
      end)
    end
  end

  defp entries(pool) do
    with {:ok, entries} <- File.ls(ZFSDataset.ownership_directory(pool)),
         true <- length(entries) <= 4096 and Enum.all?(entries, &OverallsProtocol.uuid?/1),
         do: {:ok, Enum.sort(entries)},
         else: (_ -> {:error, :backup_inventory_unconfirmed})
  end

  defp flush(directory, pool, spec) do
    with {:ok, %{state: :running} = intent} <- Intent.read(directory),
         {:ok, boot} <-
           Boot.current(directory, spec.id, {intent.execution_epoch, intent.generation}) do
      Flush.request(Path.join(Jail.root(pool, spec), "v.sock"), boot) |> Atom.to_string()
    else
      {:ok, %{state: :stopped}} -> "stopped"
      _ -> "unconfirmed"
    end
  end

  defp mount_path(pool, id), do: Path.join(["/run/overalls-backups/guests", pool.id, id])

  defp mount_snapshot(pool, id, mount) do
    with :ok <- PrivateFiles.directory("/run/overalls-backups"),
         :ok <- PrivateFiles.directory("/run/overalls-backups/guests"),
         :ok <- PrivateFiles.directory(Path.dirname(mount)),
         :ok <- PrivateFiles.directory(mount),
         {:ok, _} <-
           Command.run(
             :mount,
             ["-t", "zfs", "-o", "ro,nodev,nosuid,noexec", BackupSnapshot.name(pool, id), mount],
             30_000
           ),
         do: :ok,
         else: (_ -> {:error, :backup_mount_unconfirmed})
  end

  defp release(pool, id, run_id) do
    with {:ok, journal} when is_map(journal) <- BackupSnapshot.read(pool, id),
         true <- journal["run_id"] == run_id,
         :ok <- unmount(pool, id),
         :ok <- BackupSnapshot.cleanup(pool, id, run_id),
         do: :ok,
         else: (_ -> {:error, :backup_cleanup_unconfirmed})
  end

  defp unmount(pool, id) do
    mount = mount_path(pool, id)

    with {:ok, mounts} <- Lilly.Host.MountTable.read() do
      case Enum.filter(mounts, &(&1["target"] == mount)) do
        [] ->
          :ok

        [%{"source" => source}] ->
          if source == BackupSnapshot.name(pool, id) do
            case Command.run(:umount, ["--", mount], 30_000) do
              {:ok, _} -> :ok
              _ -> {:error, :backup_mount_busy}
            end
          else
            {:error, :backup_foreign_mount}
          end

        _ ->
          {:error, :backup_mount_unconfirmed}
      end
    else
      _ -> {:error, :backup_mount_unconfirmed}
    end
  end
end
