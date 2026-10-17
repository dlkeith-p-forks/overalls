defmodule Lilly.Transfer.SourceSnapshotCleanup do
  @moduledoc "Snapshot-only reclamation of a restored or deletion-fenced source."
  require Lilly.Events
  alias OverallsProtocol.RelocationSnapshotCleanup, as: Wire
  alias Lilly.Control.{Config, Store}
  alias Lilly.Host.{Pool, Storage, ZFS, ZFSDataset}
  alias Lilly.Transfer.{SourceExport, SourceSnapshots}
  alias Lilly.VM.{Driver, Executor}

  # @cc [owner:ghuntley,label:security;recovery] cancelled-snapshots-local-authority
  # execute/3 requires authenticated source control and no held host lock. It MUST
  # revoke/reap exports before taking placement/pool locks, match the retained
  # command and driver intent at the successor epoch for restoration, or the old
  # or successor epoch for terminal Delete, and derive disk
  # identity and snapshot ownership from local claims. Missing control descriptors
  # MUST NOT prevent cleanup of locally journaled or never-created snapshots.
  # Success requires native snapshot absence; no disk deletion, VM intent mutation,
  # destination cleanup or capacity release is authorized by this effect.
  @spec execute(Config.t(), Store.t(), Wire.command()) :: {:ok, Wire.result()} | {:error, atom()}
  def execute(config, store, request) do
    with {:ok, ^request} <- Wire.command(Wire.encode(request)) do
      authorized(config, store, request)
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security;observability] snapshot-cleanup-outcome-events
  # Validated reclamation outcomes MUST report only the relocation and
  # placement identifiers plus a closed reason atom; commands, descriptors and
  # native output MUST NOT be logged. Unvalidated requests carry no event
  # because no identifiers are trustworthy yet. Rejections MAY repeat per
  # bounded lease retry; the owning runtime keeps its own deduplicated
  # diagnostic.
  defp authorized(config, store, request) do
    with true <- request.host_id == config.client.host_id and store.host_id == request.host_id,
         true <- is_binary(config.transfer_state_dir),
         :ok <- lease(request),
         {:ok, command} <- current(store, request),
         {:ok, spec} <- Executor.specification(command),
         pool when not is_nil(pool) <- Enum.find(config.pools, &(&1.id == command.pool_id)),
         true <- pool.host_id == request.host_id,
         :ok <- SourceExport.revoke(config.transfer_state_dir, request.host_id, request.id),
         {:ok, :clean} <-
           with_source(
             config.execution,
             pool,
             spec,
             {command.execution_epoch, command.generation},
             command.kind,
             fn ->
               Storage.locked(pool, fn ->
                 with {:ok, ^command} <- current(store, request),
                      :ok <- lease(request),
                      :ok <-
                        SourceSnapshots.cleanup(pool, spec, request.id, request.execution_epoch),
                      {:ok, claim} <- ZFSDataset.snapshot_source(pool, spec),
                      :ok <-
                        ZFS.transfer_child(
                          Pool.zfs_identity(pool),
                          ZFSDataset.name(pool, spec),
                          claim.dataset_guid,
                          %{}
                        ),
                      do: {:ok, :clean},
                      else: (_ -> failure())
               end)
             end
           ),
         do: completed(request),
         else: (_ -> unconfirmed(request))
  end

  defp completed(request) do
    Lilly.Events.emit("lilly.cleanup_completed",
      relocation_id: request.id,
      placement_id: request.placement_id
    )

    {:ok, Map.take(request, [:id, :placement_id, :execution_epoch])}
  end

  defp unconfirmed(request) do
    Lilly.Events.emit("lilly.cleanup_unconfirmed",
      relocation_id: request.id,
      placement_id: request.placement_id,
      reason: :source_snapshot_cleanup_unconfirmed
    )

    failure()
  end

  defp current(store, request) do
    with {:ok, command} when is_map(command) <- Store.read(store, request.placement_id),
         true <-
           command.host_id == request.host_id and command.placement_id == request.placement_id and
             ((command.execution_epoch == request.execution_epoch + 1 and
                 command.kind in [:start, :stop]) or
                (command.kind == :delete and
                   command.execution_epoch in [
                     request.execution_epoch,
                     request.execution_epoch + 1
                   ])),
         do: {:ok, command},
         else: (_ -> failure())
  end

  defp with_source(config, pool, spec, revision, :delete, fun),
    do: Driver.with_deleted_transfer_source(config, pool, spec, revision, fun)

  defp with_source(config, pool, spec, revision, kind, fun),
    do:
      Driver.with_transfer_source(
        config,
        pool,
        spec,
        revision,
        if(kind == :start, do: :running, else: :stopped),
        fun
      )

  defp lease(request),
    do: if((request.expires_at - System.system_time(:second)) in 1..300, do: :ok, else: failure())

  defp failure, do: {:error, :source_snapshot_cleanup_unconfirmed}
end
