defmodule Lilly.Transfer.Importer do
  @moduledoc "Quiescent adoption of a received final disk without execution authority."
  require Lilly.Events
  alias Lilly.Host.{Lock, PrivateFiles, Storage}
  alias Lilly.Transfer.{ImportJournal, Key, ReceivedDataset}
  alias Lilly.VM.{Disk, Driver, Spec}

  # @cc [owner:ghuntley,label:security;recovery] import-effect-bound-to-receipt
  # adopt/2 requires current authenticated control authority. It MUST validate a
  # final descriptor and local GUID, match the configured pool and source pin,
  # exclude receive activity/native streams, and hold the placement mutation lock.
  # The local import journal MUST match before idempotent disk adoption; retries
  # after snapshot pruning MUST use retained ownership, never restart receiving.
  # Success publishes destination-local VM ownership after adoption, with no launch
  # intent or source cleanup. Ordinary activation must supply new execution authority.
  # Cached connection paths MUST be revalidated after acquiring activity/stream
  # locks, so an early cancellation key tombstone rejects delayed adoption.
  # Pool contention MUST retain its closed storage_busy classification; rejected
  # journal or disk payloads MUST NOT become diagnostic text or execution authority.
  # Journal/adoption pool acquisition may retry for two seconds while outer
  # placement/activity/stream ownership remains held; protected effects run once.
  @spec adopt(Lilly.Control.Config.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def adopt(config, wire) do
    with true <- is_nil(Lock.current()),
         {:ok, command} <- OverallsProtocol.RelocationImport.command(wire),
         true <- (command.expires_at - System.system_time(:second)) in 1..300,
         descriptor = command.descriptor,
         pool when not is_nil(pool) <-
           Enum.find(
             config.pools,
             &(&1.id == descriptor.destination.pool_id and
                 &1.host_id == descriptor.destination.host_id)
           ),
         {:ok, spec} <-
           descriptor.workload
           |> Map.drop([:architecture])
           |> Map.merge(%{id: descriptor.destination.placement_id, pool_id: pool.id})
           |> Spec.new(),
         {:ok, files} <-
           Key.connection(
             config.transfer_state_dir,
             pool.host_id,
             descriptor.relocation_id,
             spec.id,
             descriptor.source.host_id,
             command.source_endpoint
           ) do
      Driver.with_transfer_import(config.execution, pool, spec, fn ->
        owned(Path.join(Path.dirname(files.stream_dir), "receive"), fn ->
          owned(files.stream_dir, fn ->
            with {:ok, ^files} <-
                   Key.connection(
                     config.transfer_state_dir,
                     pool.host_id,
                     descriptor.relocation_id,
                     spec.id,
                     descriptor.source.host_id,
                     command.source_endpoint
                   ),
                 {:ok,
                  %{"phase" => "active", "stream_state" => "received", "dataset_guid" => guid}} <-
                   Storage.locked(
                     pool,
                     fn ->
                       ImportJournal.read(
                         ReceivedDataset.directory(pool, spec.id),
                         descriptor,
                         pool.storage
                       )
                     end,
                     2000
                   ),
                 true <- guid == command.dataset_guid,
                 :ok <- Disk.adopt(pool, descriptor),
                 do: {:ok, guid},
                 else: (
                   {:error, :storage_busy} -> {:error, :storage_busy}
                   _ -> {:error, :disk_import_unconfirmed}
                 )
          end)
        end)
      end)
      |> adopted(descriptor)
    else
      _ -> {:error, :import_authority_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:security;observability] adoption-event-correlated
  # A published adoption MUST report only the relocation and destination
  # placement identifiers after destination-local ownership is published;
  # descriptors, journals, dataset GUIDs and credentials MUST NOT be logged.
  # Rejections stay deduped runtime diagnostics and MUST NOT emit here.
  defp adopted({:ok, _guid} = result, descriptor) do
    Lilly.Events.emit("lilly.transfer_adopted",
      relocation_id: descriptor.relocation_id,
      placement_id: descriptor.destination.placement_id
    )

    result
  end

  defp adopted(error, _), do: error

  defp owned(directory, fun) do
    with :ok <- PrivateFiles.directory(directory), {:ok, lock} <- Lock.acquire(directory) do
      try do
        result = fun.()

        case Lock.release(lock) do
          :ok -> result
          _ -> {:error, :import_quiescence_unconfirmed}
        end
      after
        if Lock.held?(lock), do: Lock.release(lock)
      end
    else
      _ -> {:error, :import_busy}
    end
  end
end
