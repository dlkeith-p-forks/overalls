defmodule Lilly.Transfer.SourceCleanup do
  @moduledoc "Fenced, retryable retirement of the old source copy after handoff."
  require Lilly.Events
  alias Lilly.Control.{Config, Store}
  alias Lilly.Host.{Storage, ZFSDataset}
  alias Lilly.Transfer.{SnapshotIndex, SourceExport, SourceSnapshots}
  alias Lilly.VM.{Driver, Executor}
  alias OverallsProtocol.RelocationCleanup

  # @cc [owner:ghuntley,label:security;capacity;recovery] source-cleanup-native-proof
  # execute/3 MUST match the retained stopped source command and exact native
  # dataset/snapshot binding before deletion. It MUST permanently revoke and reap
  # source exports, then fence local launch before native effects. Only a retired
  # matching journal may retry after native disk disappearance. Success requires
  # ordinary guarded disk deletion, with ownership/tombstones retained. No peer
  # path or logical destination authority may select a different disk.
  # Only closed local stage reasons and pool-lock contention may pass
  # through as diagnostics. Rejected commands and callback payloads stay private.
  # Snapshot retirement may retry pool acquisition for two seconds before its
  # native proofs/effects; caller cancellation and all deletion fences remain.
  @spec execute(Config.t(), Store.t(), RelocationCleanup.command()) ::
          {:ok, :deleted} | {:error, atom()}
  def execute(config, store, request) do
    with {:ok, ^request} <- RelocationCleanup.command(RelocationCleanup.encode_command(request)),
         true <-
           request.descriptor.source.host_id == config.client.host_id and
             store.host_id == config.client.host_id and is_binary(config.transfer_state_dir),
         {:lease, :ok} <- {:lease, lease(request)},
         {:command, {:ok, command}} <- {:command, current(store, request)},
         {:ok, spec} <- Executor.specification(command),
         pool when not is_nil(pool) <- Enum.find(config.pools, &(&1.id == command.pool_id)),
         {:exports, :ok} <-
           {:exports, SourceExport.revoke(config.transfer_state_dir, pool.host_id, request.id)},
         {:lease, :ok} <- {:lease, lease(request)},
         :ok <-
           Driver.retire_transfer_source(
             config.execution,
             pool,
             spec,
             {command.execution_epoch, command.generation},
             fn ->
               with {:ok, ^command} <- current(store, request),
                    :ok <- lease(request),
                    do: snapshots(pool, spec, request.descriptor),
                    else: (_ -> {:error, :source_cleanup_unconfirmed})
             end
           ),
         do: completed(request),
         else: (
           {:lease, _} ->
             unconfirmed(request, :source_lease_unconfirmed)

           {:command, _} ->
             unconfirmed(request, :source_command_unconfirmed)

           {:exports, _} ->
             unconfirmed(request, :source_exports_unconfirmed)

           {:error, :execution_unavailable} ->
             unconfirmed(request, :source_execution_unavailable)

           {:error, :storage_busy} = busy ->
             busy

           {:error, reason}
           when reason in [
                  :source_claim_unconfirmed,
                  :source_intent_unconfirmed,
                  :source_unit_unconfirmed,
                  :source_jail_unconfirmed,
                  :source_network_unconfirmed,
                  :source_fence_unconfirmed,
                  :source_tombstone_unconfirmed,
                  :source_boot_log_unconfirmed,
                  :source_snapshots_unconfirmed,
                  :source_disk_delete_unconfirmed
                ] ->
             unconfirmed(request, reason)

           _ ->
             unconfirmed(request, :source_cleanup_unconfirmed)
         )
  end

  # @cc [owner:ghuntley,label:security;observability] source-cleanup-outcome-events
  # Cleanup outcomes MUST report only the relocation and source placement
  # identifiers plus a closed reason atom; descriptors, workload payloads and
  # native output MUST NOT be logged. Expected pool contention stays a quiet
  # retry. Rejections MAY repeat per bounded lease retry; the owning runtime
  # keeps its own deduplicated effect diagnostic.
  defp completed(request) do
    Lilly.Events.emit("lilly.cleanup_completed",
      relocation_id: request.descriptor.relocation_id,
      placement_id: request.descriptor.source.placement_id
    )

    {:ok, :deleted}
  end

  defp unconfirmed(request, reason) do
    Lilly.Events.emit("lilly.cleanup_unconfirmed",
      relocation_id: request.descriptor.relocation_id,
      placement_id: request.descriptor.source.placement_id,
      reason: reason
    )

    {:error, reason}
  end

  defp current(store, request) do
    d = request.descriptor

    with {:ok, command} when is_map(command) <- Store.read(store, d.source.placement_id),
         true <-
           command.kind == :stop and command.vm_id == d.vm_id and
             command.host_id == d.source.host_id and command.pool_id == d.source.pool_id and
             command.placement_id == d.source.placement_id and
             command.execution_epoch == d.source_epoch and
             command.generation == request.generation and
             Map.take(command, Map.keys(d.workload)) == d.workload,
         do: {:ok, command},
         else: (_ -> {:error, :source_cleanup_unconfirmed})
  end

  defp snapshots(pool, spec, descriptor) do
    Storage.locked(
      pool,
      fn ->
        with {:ok, history, guid} <- ZFSDataset.transfer_history(pool, spec),
             true <- guid == descriptor.stream.source_dataset_guid,
             {:ok, current} when is_map(current) <- SnapshotIndex.current(history),
             true <-
               current.binding.relocation_id == descriptor.relocation_id and
                 current.binding.execution_epoch == descriptor.source_epoch and
                 current.binding.dataset_guid == descriptor.stream.source_dataset_guid and
                 current.binding.host_id == pool.host_id and current.binding.pool_id == pool.id and
                 current.binding.placement_id == spec.id and
                 current.binding.zpool_guid == pool.storage.zpool_guid and
                 current.binding.parent_dataset_guid == pool.storage.dataset_guid and
                 get_in(current.journal, ["snapshots", SourceSnapshots.slot(), "guid"]) ==
                   descriptor.stream.to_guid do
          if current.journal["phase"] == "retired" do
            # Disk.delete below still verifies the native claim or deletion tombstone.
            :ok
          else
            with {:ok, native} <- ZFSDataset.snapshot_source(pool, spec),
                 true <- native.dataset_guid == descriptor.stream.source_dataset_guid,
                 do:
                   SourceSnapshots.cleanup(
                     pool,
                     spec,
                     descriptor.relocation_id,
                     descriptor.source_epoch
                   ),
                 else: (_ -> {:error, :source_cleanup_unconfirmed})
          end
        else
          _ -> {:error, :source_cleanup_unconfirmed}
        end
      end,
      2000
    )
  end

  defp lease(request) do
    if (request.expires_at - System.system_time(:second)) in 1..300,
      do: :ok,
      else: {:error, :source_cleanup_unconfirmed}
  end
end
