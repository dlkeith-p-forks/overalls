defmodule Lilly.Transfer.ImportCleanup do
  @moduledoc "Permanent local retirement of received or partially adopted destination data."
  require Lilly.Events
  alias OverallsProtocol.DiskTransfer, as: Relocation
  alias Lilly.Host.{Command, Lock, Pool, PrivateFiles, ZFS, ZFSDataset}
  alias Lilly.Transfer.{ImportJournal, ReceivedDataset}
  alias Lilly.VM.Spec
  @type failure :: {:error, :import_cleanup_unconfirmed}

  # @cc [owner:ghuntley,label:security;recovery] import-cleanup-without-remote-lineage
  # cleanup_intent/2 requires current cancellation/deletion authority, permanent
  # key and launch fences, proven stream/VMM/jail quiescence and the pool lock.
  # It MUST use locally journaled lineage for existing imports. Missing history
  # permits only verified native and claim absence, never reconstructed ownership
  # or invented stream GUIDs. Corrupt history MUST fail closed. Success proves only
  # local storage reclamation; callers retain the fences and cleanup obligations.
  @spec cleanup_intent(Pool.t(), Relocation.intent()) :: :ok | failure()
  def cleanup_intent(pool, %{destination: %{placement_id: id}} = intent) do
    with true <- OverallsProtocol.uuid?(id),
         {:ok, history} <-
           ImportJournal.for_intent(
             ReceivedDataset.directory(pool, id),
             intent,
             pool.storage
           ),
         true <-
           intent.destination.host_id == pool.host_id and intent.destination.pool_id == pool.id do
      case history do
        %{descriptor: descriptor} ->
          cleanup(pool, descriptor)

        nil ->
          with {:ok, spec} <-
                 intent.workload
                 |> Map.drop([:architecture])
                 |> Map.merge(%{id: intent.destination.placement_id, pool_id: pool.id})
                 |> Spec.new(),
               :ok <- ZFSDataset.bind(pool),
               :ok <- ZFS.absent_child(Pool.zfs_identity(pool), ZFSDataset.name(pool, spec)),
               {:ok, :staging} <- ZFSDataset.fence_import_cleanup(pool, spec, nil),
               :ok <- remove_mountpoint(ZFSDataset.directory(pool, spec)),
               do: :ok,
               else: (_ -> unconfirmed(intent.relocation_id, id))
      end
    else
      _ -> unconfirmed(intent.relocation_id, id)
    end
  end

  def cleanup_intent(_, _), do: {:error, :import_cleanup_unconfirmed}

  # @cc [owner:ghuntley,label:security;recovery] import-cleanup-requires-fences-and-physical-absence
  # cleanup/2 requires the destination pool lock, current deletion/cancellation
  # authority and proven absence of stream processes, VMMs and jail access. It MUST
  # fence any matching ordinary claim and the import journal before native effects,
  # bind an interrupted receive only through its pre-existing local nonce, and
  # destroy only its exact GUID and known snapshots without force/recursive flags.
  # Missing journals MUST NOT reconstruct ownership from received data. Retired
  # retries verify absence only. Success requires native/mount absence and durable
  # tombstones; it does not itself release commitments or transfer slots.
  @spec cleanup(Pool.t(), Relocation.descriptor()) :: :ok | failure()
  def cleanup(
        pool,
        %{destination: %{placement_id: id, host_id: host, pool_id: pool_id}} = descriptor
      ) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         true <- host == pool.host_id and pool_id == pool.id and OverallsProtocol.uuid?(id),
         directory = ReceivedDataset.directory(pool, id),
         {:ok, previous} <- ImportJournal.read(directory, descriptor, pool.storage),
         :ok <- ZFSDataset.bind(pool),
         {:ok, spec} <-
           descriptor.workload
           |> Map.drop([:architecture])
           |> Map.merge(%{id: id, pool_id: pool.id})
           |> Spec.new(),
         :ok <- initial_absence(pool, spec, previous),
         {:ok, policy} <- ZFSDataset.fence_import_cleanup(pool, spec, previous),
         :ok <- PrivateFiles.directory(Path.dirname(directory)),
         {:ok, _} <- Command.run(:sync, ["--", Path.dirname(Path.dirname(directory))]),
         {:ok, journal} <- ImportJournal.retire(directory, descriptor, pool.storage),
         {:ok, current} <-
           descriptor
           |> Relocation.encode_descriptor()
           |> Map.put("stream", journal["stream"])
           |> Relocation.descriptor(),
         {:ok, journal} <- remove(pool, spec, current, journal, policy),
         :ok <- ZFS.absent_child(Pool.zfs_identity(pool), ZFSDataset.name(pool, spec)),
         :ok <- remove_mountpoint(ZFSDataset.directory(pool, spec)),
         :ok <- ZFSDataset.finish_import_cleanup(pool, spec, journal),
         {:ok, _} <-
           ImportJournal.deleted(directory, current, pool.storage, journal["dataset_guid"]) do
      completed(descriptor, id)
    else
      _ -> unconfirmed(descriptor.relocation_id, id)
    end
  end

  def cleanup(_, _), do: {:error, :import_cleanup_unconfirmed}

  # @cc [owner:ghuntley,label:security;observability] import-cleanup-outcome-events
  # Destructive import cleanup MUST report completion with only the relocation
  # and destination placement identifiers; rejections add the closed reason
  # atom. Descriptors, journals, GUIDs, nonces and native output MUST NOT be
  # logged. Events MUST be suppressed when either identifier is not a
  # trustworthy UUID, so unvalidated payloads cannot reach a log destination.
  # Absence-only verification of missing history emits no completion event
  # because nothing was destroyed. Rejections MAY repeat per bounded lease
  # retry; owning runtimes keep their own deduplicated diagnostics.
  defp completed(descriptor, id) do
    if OverallsProtocol.uuid?(descriptor.relocation_id) and OverallsProtocol.uuid?(id) do
      Lilly.Events.emit("lilly.cleanup_completed",
        relocation_id: descriptor.relocation_id,
        placement_id: id
      )
    end

    :ok
  end

  defp unconfirmed(relocation, id) do
    if OverallsProtocol.uuid?(relocation) and OverallsProtocol.uuid?(id) do
      Lilly.Events.emit("lilly.cleanup_unconfirmed",
        relocation_id: relocation,
        placement_id: id,
        reason: :import_cleanup_unconfirmed
      )
    end

    {:error, :import_cleanup_unconfirmed}
  end

  defp initial_absence(pool, spec, nil),
    do: ZFS.absent_child(Pool.zfs_identity(pool), ZFSDataset.name(pool, spec))

  defp initial_absence(_, _, _), do: :ok

  defp remove(pool, spec, _descriptor, %{"phase" => "retired"} = journal, _) do
    with :ok <- ZFS.absent_child(Pool.zfs_identity(pool), ZFSDataset.name(pool, spec)),
         do: {:ok, journal}
  end

  defp remove(pool, spec, _descriptor, journal, :absent) do
    with :ok <- ZFS.absent_child(Pool.zfs_identity(pool), ZFSDataset.name(pool, spec)),
         do: {:ok, journal}
  end

  defp remove(pool, spec, descriptor, journal, policy) do
    name = ZFSDataset.name(pool, spec)

    with {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)) do
      case owners[name] do
        nil ->
          {:ok, journal}

        %{"guid" => guid} ->
          with true <- journal["dataset_guid"] in [nil, guid],
               true <- ReceivedDataset.local_owner?(pool, spec.id, journal["nonce"]),
               {:ok, _, _, _} <- inspect(pool, spec, descriptor, journal, guid, policy),
               {:ok, bound} <- bind_guid(pool, spec, descriptor, journal, guid),
               :ok <- destroy(pool, spec, descriptor, bound, policy),
               do: {:ok, bound}
      end
    end
  end

  defp bind_guid(pool, spec, descriptor, %{"dataset_guid" => nil} = journal, guid),
    do:
      ImportJournal.bind(
        ReceivedDataset.directory(pool, spec.id),
        descriptor,
        pool.storage,
        journal["nonce"],
        guid
      )

  defp bind_guid(_, _, _, journal, _), do: {:ok, journal}

  defp destroy(pool, spec, descriptor, journal, policy) do
    name = ZFSDataset.name(pool, spec)

    with {:ok, _, _, resumable} <-
           inspect(pool, spec, descriptor, journal, journal["dataset_guid"], policy),
         :ok <- abort_receive(name, resumable),
         {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)) do
      if Map.has_key?(owners, name) do
        with {:ok, retained, mounted, false} <-
               inspect(pool, spec, descriptor, journal, journal["dataset_guid"], policy),
             :ok <- remove_snapshots(name, retained),
             :ok <- unmount(name, mounted),
             {:ok, remaining, :unmounted, false} when map_size(remaining) == 0 <-
               inspect(pool, spec, descriptor, journal, journal["dataset_guid"], policy),
             {:ok, _} <- Command.run(:zfs_destroy, [name], 30_000),
             do: :ok
      else
        :ok
      end
    end
  end

  defp inspect(pool, spec, descriptor, journal, guid, policy) do
    name = ZFSDataset.name(pool, spec)
    snapshots = ReceivedDataset.snapshots(name, guid, descriptor)

    with true <- ReceivedDataset.local_owner?(pool, spec.id, journal["nonce"]),
         {:ok, _, _, _} = result <-
           ZFS.cleanup_child(Pool.zfs_identity(pool), name, guid, snapshots, policy),
         true <- ReceivedDataset.local_owner?(pool, spec.id, journal["nonce"]),
         do: result
  end

  defp abort_receive(_, false), do: :ok
  defp abort_receive(name, true), do: command(:zfs_receive_abort, [name])
  defp unmount(_, :unmounted), do: :ok
  defp unmount(name, :mounted), do: command(:zfs_unmount, [name])
  defp command(name, args), do: with({:ok, _} <- Command.run(name, args, 30_000), do: :ok)

  defp remove_snapshots(name, retained) do
    snapshot = name <> "@" <> Lilly.Transfer.SnapshotJournal.slot()

    if Map.has_key?(retained, snapshot), do: command(:zfs_destroy, [snapshot]), else: :ok
  end

  defp remove_mountpoint(path) do
    case Lilly.Host.Privilege.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory, uid: 0}} ->
        with :ok <- File.rmdir(path),
             {:ok, _} <- Command.run(:sync, ["--", Path.dirname(path)]),
             do: :ok

      _ ->
        :error
    end
  end
end
