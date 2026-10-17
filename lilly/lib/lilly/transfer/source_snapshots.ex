defmodule Lilly.Transfer.SourceSnapshots do
  @moduledoc "Owned native source snapshots with durable intent, retry recovery and nonrecursive cleanup."
  require Lilly.Events
  alias Lilly.Host.{Command, Lock, Pool, ZFS, ZFSDataset}
  alias Lilly.Transfer.{SnapshotIndex, SnapshotJournal, SnapshotOwnership}
  alias Lilly.VM.Spec
  @type failure :: {:error, :source_snapshot_unconfirmed}
  @typedoc "Absolute sender argv for the source host's root export worker."
  @type command :: {Path.t(), [String.t()]}
  @typedoc "Cleanup names the closed stage atom of the check that failed."
  @type cleanup_failure :: {:error, atom()}

  # @cc [owner:ghuntley,label:security;recovery] native-snapshot-effect-bound-to-intent
  # create/4 requires the caller's pool lock, current relocation/execution authority
  # and proven physical stop: the transfer's single snapshot is always of a stopped
  # disk (ADR-0155). It MUST bind the ready local disk, persist index/nonce before
  # native creation, reject foreign markers and replaced/missing bound snapshots,
  # and verify native policy/GUIDs before publishing success. Uncertain create
  # results retain intent.
  @spec create(Pool.t(), Spec.t(), OverallsProtocol.uuid(), pos_integer()) ::
          {:ok, String.t()} | failure()
  @spec create(Pool.t(), Spec.t(), OverallsProtocol.uuid(), pos_integer(), :relocation | :clone) ::
          {:ok, String.t()} | failure()
  def create(pool, spec, relocation, epoch, purpose \\ :relocation) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         :ok <- ZFSDataset.bind(pool),
         {:ok, claim} <- ZFSDataset.snapshot_source(pool, spec),
         binding = binding(pool, claim.dataset_guid, spec.id, relocation, epoch),
         metadata = ZFSDataset.metadata_directory(pool, spec),
         {:ok, current} <- SnapshotIndex.prepare(metadata, binding, purpose),
         name = ZFSDataset.name(pool, spec) <> "@" <> slot(),
         slot = current.journal["snapshots"][slot()],
         {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)),
         {:ok, guid} <- materialize(pool, spec, current, name, purpose, slot, owners[name]),
         {:ok, latest} <- SnapshotIndex.current(metadata),
         true <- latest.binding == binding,
         {:ok, expected} <- known(pool, spec, latest),
         :ok <-
           ZFS.transfer_child(
             Pool.zfs_identity(pool),
             ZFSDataset.name(pool, spec),
             claim.dataset_guid,
             expected
           ) do
      {:ok, guid}
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security] source-export-revalidates-owned-lineage
  # export/2 requires the pool lock and separately established current transfer
  # authority. It MUST derive send arguments only from the local ready disk claim,
  # active relocation index and exact native snapshot GUID/nonce bindings. It MUST
  # reject stale epochs, retired/incomplete journals, foreign snapshots and wrong
  # dataset/snapshot lineage without creating or repairing state. Returned argv
  # is not a permit: the caller MUST own the transfer slot, fence cleanup/launch
  # races and enforce expiry/revocation before and throughout native execution.
  @spec export(Pool.t(), map()) :: {:ok, Lilly.Transfer.SourceSnapshots.command()} | failure()
  def export(pool, wire) do
    with {:ok, capture} <- capture(pool, wire),
         executable when is_binary(executable) <- System.find_executable("zfs") do
      {:ok, {executable, capture.arguments}}
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] capture-shares-export-lineage
  # capture/2 MUST apply exactly the export lineage checks (pool lock, owned
  # ready source claim, bound index, active ready slots, exact snapshot GUIDs and
  # transfer-child policy) and return the verified dataset, snapshot and GUIDs.
  # It grants no authority: callers still own the permit, slot and effect fences.
  @doc false
  @spec capture(Pool.t(), map()) ::
          {:ok,
           %{
             spec: Spec.t(),
             dataset: String.t(),
             snapshot: String.t(),
             dataset_guid: String.t(),
             to_guid: String.t(),
             arguments: [String.t()]
           }}
          | failure()
  def capture(pool, wire) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         {:ok, descriptor} <- OverallsProtocol.DiskTransfer.descriptor(wire),
         true <-
           descriptor.source.host_id == pool.host_id and descriptor.source.pool_id == pool.id,
         {:ok, spec} <-
           OverallsProtocol.DiskTransfer.source_workload(descriptor)
           |> Map.drop([:architecture])
           |> Map.merge(%{id: descriptor.source.placement_id, pool_id: pool.id})
           |> Spec.new(),
         {:ok, claim} <- ZFSDataset.snapshot_source(pool, spec),
         true <- claim.dataset_guid == descriptor.stream.source_dataset_guid,
         {:ok, current} when is_map(current) <-
           SnapshotIndex.current(ZFSDataset.metadata_directory(pool, spec)),
         true <-
           current.binding ==
             binding(
               pool,
               claim.dataset_guid,
               spec.id,
               descriptor.relocation_id,
               descriptor.source_epoch
             ),
         true <- current.journal["phase"] == "active",
         true <-
           Enum.all?(current.journal["snapshots"], fn {_, slot} -> slot["state"] == "ready" end),
         {:ok, arguments} <-
           send_arguments(
             ZFSDataset.name(pool, spec),
             descriptor.stream,
             current.journal["snapshots"]
           ),
         {:ok, expected} <- known(pool, spec, current),
         :ok <-
           ZFS.transfer_child(
             Pool.zfs_identity(pool),
             ZFSDataset.name(pool, spec),
             claim.dataset_guid,
             expected
           ) do
      {:ok,
       %{
         spec: spec,
         dataset: ZFSDataset.name(pool, spec),
         snapshot: List.last(arguments),
         dataset_guid: claim.dataset_guid,
         to_guid: descriptor.stream.to_guid,
         arguments: arguments
       }}
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] resumed-export-revalidates-native-lineage
  # resume_export/3 has the same pool-lock and current-permit preconditions as
  # export/2. It MUST first revalidate the ordinary owned snapshot lineage, then
  # require a bounded token naming that exact source snapshot and matching both
  # GUIDs. Returned argv grants no authority and MUST remain subject to the same
  # stream ownership, expiry and revocation supervision as an ordinary export.
  @spec resume_export(Pool.t(), map(), term()) ::
          {:ok, Lilly.Transfer.SourceSnapshots.command()} | failure()
  def resume_export(pool, wire, token) do
    with {:ok, {executable, arguments}} <- export(pool, wire),
         {:ok, descriptor} <- OverallsProtocol.DiskTransfer.descriptor(wire),
         :ok <-
           Lilly.Transfer.ResumeToken.validate(List.last(arguments), descriptor.stream, token),
         do: {:ok, {executable, ["send", "-t", token]}},
         else: (_ -> failure())
  end

  # @cc [owner:ghuntley,label:security;recovery] local-producer-shares-export-lineage
  # local_producer/3 MUST apply export/2's lineage checks (and, with a token,
  # resume_export/3's token binding) and return only the typed local send
  # fields of that verified snapshot, `<dataset>/vm-<placement>@lilly-b`, from
  # which hostd derives the send (hostd-transfer-stream-typed). It grants no
  # authority: the caller still owns the permit, slot and effect fences.
  @spec local_producer(Pool.t(), map(), String.t() | nil) ::
          {:ok, Lilly.Transfer.Stream.producer()} | failure()
  def local_producer(pool, wire, token \\ nil) do
    with {:ok, capture} <- capture(pool, wire),
         true <- capture.snapshot == ZFSDataset.name(pool, capture.spec) <> "@" <> slot() do
      fields = %{dataset: pool.storage.dataset, placement: capture.spec.id}

      if is_nil(token) do
        {:ok, {:local_send, fields}}
      else
        with {:ok, descriptor} <- OverallsProtocol.DiskTransfer.descriptor(wire),
             :ok <-
               Lilly.Transfer.ResumeToken.validate(capture.snapshot, descriptor.stream, token),
             do:
               {:ok,
                {:local_resume,
                 Map.merge(fields, %{to_guid: descriptor.stream.to_guid, token: token})}},
             else: (_ -> failure())
      end
    else
      _ -> failure()
    end
  end

  # Streams are sent compressed (-c): already-lz4 blocks travel as stored rather than
  # being decompressed and recompressed, roughly halving bytes for typical guest disks.
  # The snapshot remains the final argument so resumed exports bind the same name.
  defp send_arguments(name, %{to_guid: guid}, slots) do
    suffix = slot()

    case slots do
      %{^suffix => %{"guid" => ^guid}} when map_size(slots) == 1 ->
        {:ok, ["send", "-c", name <> "@" <> suffix]}

      _ ->
        failure()
    end
  end

  @doc "The single native snapshot suffix bound by every transfer journal."
  @spec slot() :: String.t()
  def slot, do: SnapshotJournal.slot()

  # @cc [owner:ghuntley,label:security;recovery] snapshot-cleanup-never-destroys-by-name-alone
  # cleanup/4 requires the caller's pool lock and confirmed stream quiescence. It
  # MUST fence creation before deletion, match the exact local nonce and GUID,
  # recover interrupted creates only for cleanup, use nonrecursive/nonforced destroy,
  # and confirm absence before each tombstone. Historical retired retries MUST NOT
  # touch a newer relocation's snapshots, even when native names have been reused.
  # Success is snapshot cleanup only, never source-disk cleanup or execution authority.
  # A failure MUST name only the closed stage atom of the check that refused
  # (ownership binding, claim shape, index, journal or native removal), never
  # native output, so a stuck prune is diagnosable from one event.
  @spec cleanup(Pool.t(), Spec.t(), OverallsProtocol.uuid(), pos_integer()) ::
          :ok | cleanup_failure()
  @spec cleanup(Pool.t(), Spec.t(), OverallsProtocol.uuid(), pos_integer(), :relocation | :clone) ::
          :ok | cleanup_failure()
  def cleanup(pool, spec, relocation, epoch, purpose \\ :relocation) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         :ok <- ZFSDataset.bind(pool),
         {:ok, claim} <- ZFSDataset.snapshot_source(pool, spec),
         binding = binding(pool, claim.dataset_guid, spec.id, relocation, epoch),
         {:ok, current} <-
           SnapshotIndex.begin_retire(ZFSDataset.metadata_directory(pool, spec), binding, purpose) do
      if current.journal["phase"] == "retired" do
        :ok
      else
        with :ok <- remove(pool, spec, current),
             {:ok, _} <- SnapshotJournal.finish_retire(current.directory, binding),
             do: destroyed(relocation, spec.id, purpose),
             else: (error -> stage(error))
      end
    else
      error -> stage(error)
    end
  end

  defp stage({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp stage(_), do: failure()

  # @cc [owner:ghuntley,label:security;observability] snapshot-transition-events
  # Snapshot events MUST fire only on the durable native transition: a fresh
  # creation after the snapshot command and journal bind confirmed, and a
  # destroy after the retirement tombstone finishes. Idempotent re-verification
  # of already ready or already retired snapshots MUST NOT re-emit. Events MUST
  # carry only relocation and placement identifiers; GUIDs, nonces, paths and
  # native output MUST NOT be logged.
  defp created(relocation, placement, purpose, guid) when purpose == :relocation do
    Lilly.Events.emit("lilly.snapshot_created",
      relocation_id: relocation,
      placement_id: placement
    )

    {:ok, guid}
  end

  defp created(_, _, _, guid), do: {:ok, guid}

  defp destroyed(relocation, placement, :relocation) do
    Lilly.Events.emit("lilly.snapshot_destroyed",
      relocation_id: relocation,
      placement_id: placement
    )

    :ok
  end

  defp destroyed(_, _, _), do: :ok

  defp materialize(
         pool,
         spec,
         %{binding: %{relocation_id: relocation}} = current,
         name,
         purpose,
         %{"state" => "creating"} = slot,
         nil
       ) do
    with {:ok, expected} <- known(pool, spec, current),
         :ok <-
           ZFS.transfer_child(
             Pool.zfs_identity(pool),
             ZFSDataset.name(pool, spec),
             current.binding.dataset_guid,
             expected
           ),
         {:ok, _} <-
           Command.run(
             :zfs_snapshot,
             ["-o", "lilly:transfer_nonce=" <> slot["nonce"], name],
             30_000
           ),
         {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)),
         {:ok, guid} <- bind_native(pool, spec, current, name, slot, owners[name]),
         do: created(relocation, spec.id, purpose, guid),
         else: (_ -> failure())
  end

  defp materialize(pool, spec, current, name, purpose, slot, owner)
       when purpose in [:relocation, :clone],
       do: bind_native(pool, spec, current, name, slot, owner)

  defp bind_native(pool, spec, current, name, slot, %{"guid" => guid}) do
    with true <- is_nil(slot["guid"]) or slot["guid"] == guid,
         true <- SnapshotOwnership.marker?(name, slot["nonce"]),
         {:ok, expected} <- known(pool, spec, current),
         expected =
           Map.put(expected, name, %{
             dataset_guid: current.binding.dataset_guid,
             snapshot_guid: guid
           }),
         :ok <-
           ZFS.transfer_child(
             Pool.zfs_identity(pool),
             ZFSDataset.name(pool, spec),
             current.binding.dataset_guid,
             expected
           ),
         {:ok, _} <-
           SnapshotJournal.bind(current.directory, current.binding, slot["nonce"], guid),
         do: {:ok, guid},
         else: (_ -> failure())
  end

  defp bind_native(_, _, _, _, _, _), do: failure()

  # @cc [owner:ghuntley,label:recovery;security] transfer-keeps-independent-backup-snapshot
  # Transfer policy checks MUST include a concurrently ready backup's exact
  # GUID/nonce expectation, without exporting or deleting that backup snapshot.
  # An uncertain backup journal MUST still reject native policy validation.
  @spec known(Pool.t(), Spec.t(), SnapshotIndex.current()) :: {:ok, ZFS.snapshots()} | failure()
  defp known(pool, spec, current) do
    with {:ok, expected} <- transfer_known(current, ZFSDataset.name(pool, spec)),
         {:ok, backup} <- Lilly.Host.BackupSnapshot.expectations(pool, spec.id),
         do: {:ok, Map.merge(expected, backup)},
         else: (_ -> failure())
  end

  defp transfer_known(current, dataset) do
    Enum.reduce_while(current.journal["snapshots"], {:ok, %{}}, fn {suffix, slot},
                                                                   {:ok, expected} ->
      case slot do
        %{"state" => "creating", "guid" => nil} ->
          {:cont, {:ok, expected}}

        %{"state" => "ready", "guid" => guid} ->
          name = dataset <> "@" <> suffix

          if SnapshotOwnership.marker?(name, slot["nonce"]),
            do:
              {:cont,
               {:ok,
                Map.put(expected, name, %{
                  dataset_guid: current.binding.dataset_guid,
                  snapshot_guid: guid
                })}},
            else: {:halt, failure()}

        _ ->
          {:halt, failure()}
      end
    end)
  end

  defp remove(pool, spec, current) do
    suffix = slot()
    name = ZFSDataset.name(pool, spec) <> "@" <> suffix

    with {:ok, journal} <- SnapshotJournal.read(current.directory, current.binding) do
      case journal["snapshots"][suffix] do
        nil ->
          :ok

        %{"state" => "deleted"} ->
          :ok

        slot ->
          with {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)) do
            case owners[name] do
              nil ->
                with {:ok, _} <-
                       SnapshotJournal.deleted(
                         current.directory,
                         current.binding,
                         slot["guid"]
                       ),
                     do: :ok

              %{"guid" => guid} ->
                with true <- is_nil(slot["guid"]) or slot["guid"] == guid,
                     true <- SnapshotOwnership.marker?(name, slot["nonce"]),
                     {:ok, _} <-
                       SnapshotJournal.bind(
                         current.directory,
                         current.binding,
                         slot["nonce"],
                         guid
                       ),
                     {:ok, _} <- Command.run(:zfs_destroy, [name], 30_000),
                     {:ok, after_destroy} <- ZFS.owners(Pool.zfs_identity(pool)),
                     false <- Map.has_key?(after_destroy, name),
                     {:ok, _} <-
                       SnapshotJournal.deleted(current.directory, current.binding, guid),
                     do: :ok,
                     else: (_ -> failure())
            end
          end
      end
    end
  end

  defp binding(pool, guid, placement, relocation, epoch),
    do: %{
      host_id: pool.host_id,
      pool_id: pool.id,
      placement_id: placement,
      relocation_id: relocation,
      zpool_guid: pool.storage.zpool_guid,
      parent_dataset_guid: pool.storage.dataset_guid,
      dataset_guid: guid,
      execution_epoch: epoch
    }

  defp failure, do: {:error, :source_snapshot_unconfirmed}
end
