defmodule Lilly.Transfer.Source do
  @moduledoc "Authenticated snapshot/permit requests joined to local execution and native ownership."
  alias Lilly.Control.{Config, Store}
  alias Lilly.Host.{Lock, Storage, ZFSDataset}
  alias Lilly.Transfer.{Permit, PermitJournal, SnapshotIndex, SourceSnapshots}
  alias Lilly.VM.{Driver, Executor}
  alias OverallsProtocol.{Relocation, RelocationSource}

  # @cc [owner:ghuntley,label:security;recovery] source-command-guarded-native-grant
  # execute/3 requires the live authenticated runtime and its host-owned store.
  # It MUST match the source command to retained execution identity/shape and
  # driver intent before creating snapshots or granting access. The source MUST
  # have no running VMM: disk relocation requires stopped intent; memory
  # relocation requires paused intent and its exact ready checkpoint. Roots/pools
  # come only from local configuration. A first grant
  # MUST hold the stable export lock while creating its snapshot and permit;
  # lease renewal may retain an already active matching stream. Native ownership
  # and lease time MUST be rechecked before publication. Failure MUST NOT release
  # any commitment.
  @spec execute(Config.t(), Store.t(), RelocationSource.command()) ::
          {:ok, RelocationSource.result()} | {:error, atom()}
  def execute(config, store, request) do
    with {:ok, ^request} <- RelocationSource.command(RelocationSource.encode_command(request)),
         true <-
           request.intent.source.host_id == config.client.host_id and
             store.host_id == config.client.host_id and is_binary(config.transfer_state_dir),
         :ok <- lease(request),
         {:ok, command} <- current(store, request),
         {:ok, spec} <- Executor.specification(command),
         pool when not is_nil(pool) <-
           Enum.find(config.pools, &(&1.id == request.intent.source.pool_id)) do
      Driver.with_transfer_source(
        config.execution,
        pool,
        spec,
        {request.intent.source_epoch, request.generation},
        if(Map.has_key?(request.intent, :checkpoint), do: :paused, else: :stopped),
        fn ->
          guarded_stream(config.transfer_state_dir, request, fn ->
            Storage.locked(pool, fn ->
              with {:ok, ^command} <- current(store, request),
                   {:ok, claim} <- ZFSDataset.snapshot_source(pool, spec),
                   :ok <- lineage(pool, spec, request),
                   :ok <- checkpoint_source(pool, spec, request.intent),
                   :ok <- lease(request),
                   {:ok, guid} <-
                     SourceSnapshots.create(
                       pool,
                       spec,
                       request.intent.relocation_id,
                       request.intent.source_epoch
                     ),
                   true <- request.to_guid == nil or request.to_guid == guid,
                   descriptor =
                     Map.put(request.intent, :stream, %{
                       source_dataset_guid: claim.dataset_guid,
                       to_guid: guid
                     }),
                   wire = Relocation.encode_descriptor(descriptor),
                   {:ok, ^descriptor} <- Relocation.descriptor(wire),
                   {:ok, ^command} <- current(store, request),
                   :ok <- lease(request),
                   :ok <-
                     Permit.issue(
                       config.transfer_state_dir,
                       pool,
                       wire,
                       request.public_key,
                       request.revision,
                       request.expires_at
                     ) do
                {:ok, %{id: request.id, descriptor: descriptor}}
              else
                _ -> {:error, :source_request_unconfirmed}
              end
            end)
          end)
        end
      )
    else
      _ -> {:error, :source_request_unconfirmed}
    end
  end

  defp current(store, request) do
    i = request.intent

    with {:ok, command} when is_map(command) <- Store.read(store, i.source.placement_id),
         true <-
           command.vm_id == i.vm_id and command.host_id == i.source.host_id and
             command.pool_id == i.source.pool_id and command.execution_epoch == i.source_epoch and
             command.generation == request.generation,
         true <- Map.take(command, Map.keys(i.workload)) == i.workload,
         true <- command.kind == if(Map.has_key?(i, :checkpoint), do: :pause, else: :stop),
         do: {:ok, command},
         else: (_ -> {:error, :source_authority_unconfirmed})
  end

  defp checkpoint_source(pool, spec, %{checkpoint: descriptor}) do
    with {:ok, ^descriptor, _} <- Lilly.VM.Checkpoint.ready(pool, spec, descriptor), do: :ok
  end

  defp checkpoint_source(_, _, _), do: :ok

  defp lease(request) do
    remaining = request.expires_at - System.system_time(:second)
    if remaining in 1..300, do: :ok, else: {:error, :source_lease_expired}
  end

  # A renewal pinning an earlier snapshot GUID MUST find exactly that ready
  # snapshot under this relocation's current index; a first request pins nothing.
  defp lineage(_pool, _spec, %{to_guid: nil}), do: :ok

  defp lineage(pool, spec, request) do
    with {:ok, current} when is_map(current) <-
           SnapshotIndex.current(ZFSDataset.metadata_directory(pool, spec)),
         true <-
           current.binding.relocation_id == request.intent.relocation_id and
             current.binding.execution_epoch == request.intent.source_epoch,
         true <-
           match?(
             %{"state" => "ready", "guid" => guid} when guid == request.to_guid,
             current.journal["snapshots"][SourceSnapshots.slot()]
           ),
         do: :ok,
         else: (_ -> {:error, :source_lineage_unconfirmed})
  end

  defp guarded_stream(root, request, fun) do
    if same_grant?(root, request), do: fun.(), else: exclusive_stream(root, request, fun)
  end

  defp same_grant?(root, request) do
    with true <- request.to_guid != nil,
         {:ok, grant} <-
           PermitJournal.lookup(
             root,
             request.intent.source.host_id,
             request.intent.relocation_id,
             request.public_key,
             System.system_time(:second)
           ),
         true <-
           Map.delete(grant.descriptor, :stream) == request.intent and
             grant.descriptor.stream.to_guid == request.to_guid,
         do: true,
         else: (_ -> false)
  end

  defp exclusive_stream(root, request, fun) do
    directory = Path.join([root, "exports", request.intent.relocation_id, "stream"])

    with :ok <-
           PermitJournal.prepare(
             root,
             request.intent.source.host_id,
             request.intent.relocation_id
           ),
         {:ok, lock} <- Lock.acquire(directory) do
      try do
        fun.()
      after
        Lock.release(lock)
      end
    else
      _ ->
        {:error, :source_stream_busy}
    end
  end
end
