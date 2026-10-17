defmodule Lilly.Clone.Effects do
  @moduledoc "Host-owned clone effects, using independent ZFS disks and scoped transfer permits."
  require Lilly.Events
  alias OverallsProtocol.DiskTransfer
  alias Lilly.Control.Store
  alias Lilly.Host.{Lock, PrivateFiles, Storage, ZFSDataset}

  alias Lilly.Transfer.{
    CloneCopy,
    ImportCleanup,
    Key,
    Permit,
    PermitJournal,
    ReceivedDataset,
    Receiver,
    SnapshotIndex,
    SourceExport,
    SourceSnapshots,
    SSH,
    Stream
  }

  alias Lilly.VM.{Disk, Driver, Executor, Spec}

  @spec execute(Lilly.Control.Config.t(), Store.t(), map()) :: {:ok, map()} | {:error, atom()}
  def execute(config, store, command) do
    with {:ok, ^command} <- OverallsProtocol.CloneControl.command(command),
         true <-
           command["host_id"] == config.client.host_id and store.host_id == config.client.host_id,
         true <- (command["expires_at"] - System.system_time(:second)) in 1..300,
         {:ok, intent} <- DiskTransfer.intent(command["intent"]) do
      case run(config, store, command, intent) do
        {:ok, result} ->
          effect_completed(command)
          {:ok, %{"id" => command["id"], "kind" => command["kind"], "result" => result}}

        :ok ->
          effect_completed(command)
          {:ok, %{"id" => command["id"], "kind" => command["kind"], "result" => %{}}}

        {:error, reason} when is_atom(reason) ->
          {:error, reason}

        _ ->
          {:error, :clone_effect_unconfirmed}
      end
    else
      _ -> {:error, :clone_authority_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:security;observability] clone-effect-events-correlated
  # Successful clone effects MUST report only the command's clone identifier and
  # the fixed kind atom; descriptors, endpoints, public keys and result payloads
  # MUST NOT be logged. The runtime's pending-result map bounds re-execution,
  # so retries of an acknowledged effect MUST NOT re-emit.
  defp effect_completed(%{"clone_id" => clone, "kind" => kind}) do
    if OverallsProtocol.uuid?(clone) do
      Lilly.Events.emit("lilly.clone_effect_completed", clone_id: clone, utility: utility(kind))
    end

    :ok
  end

  @doc false
  @spec utility(term()) ::
          :prepare
          | :probe
          | :connect
          | :capture
          | :copy
          | :adopt
          | :revoke
          | :discard
          | :prune
          | :unknown
  def utility("prepare"), do: :prepare
  def utility("probe"), do: :probe
  def utility("connect"), do: :connect
  def utility("capture"), do: :capture
  def utility("copy"), do: :copy
  def utility("adopt"), do: :adopt
  def utility("revoke"), do: :revoke
  def utility("discard"), do: :discard
  def utility("prune"), do: :prune
  def utility(_), do: :unknown

  defp run(config, _, %{"kind" => "prepare"}, intent) do
    with {:ok, key} <-
           Key.ensure(
             config.transfer_state_dir,
             intent.destination.host_id,
             intent.relocation_id,
             intent.destination.placement_id
           ),
         do: {:ok, %{"public_key" => key}}
  end

  defp run(config, store, %{"kind" => "probe"} = command, intent) do
    with {:ok, _} <- source_command(store, intent),
         do:
           PermitJournal.probe(
             config.transfer_state_dir,
             command["intent"],
             command["public_key"],
             intent.relocation_id,
             command["revision"],
             command["expires_at"],
             System.system_time(:second)
           )
  end

  defp run(_config, _store, %{"kind" => "connect"}, %{
         source: %{host_id: host},
         destination: %{host_id: host}
       }),
       do: :ok

  defp run(config, _, %{"kind" => "connect"} = command, intent) do
    SSH.probe(
      config.transfer_state_dir,
      ssh_request(intent),
      command["source_endpoint"],
      intent.relocation_id,
      30_000
    )
  end

  defp run(config, store, %{"kind" => "capture"} = command, intent) do
    with {:ok, current} <- source_command(store, intent),
         {:ok, spec} <- Executor.specification(current),
         pool when not is_nil(pool) <- pool(config, intent.source),
         :ok <-
           PermitJournal.prepare(config.transfer_state_dir, pool.host_id, intent.relocation_id) do
      snapshot =
        Storage.locked(pool, fn ->
          case SnapshotIndex.current(ZFSDataset.metadata_directory(pool, spec)) do
            {:ok,
             %{
               binding: %{relocation_id: id},
               journal: %{"snapshots" => %{"lilly-b" => %{"state" => "ready", "guid" => guid}}}
             }}
            when id == intent.relocation_id ->
              {:ok, guid}

            {:ok, _} ->
              :capture

            error ->
              error
          end
        end)

      captured =
        if snapshot == :capture do
          Driver.with_transfer_source(
            config.execution,
            pool,
            spec,
            {intent.source_epoch, command["source_generation"]},
            :stopped,
            fn ->
              owned(
                Path.join([config.transfer_state_dir, "exports", intent.relocation_id, "stream"]),
                fn ->
                  with :ok <-
                         PermitJournal.prepare(
                           config.transfer_state_dir,
                           pool.host_id,
                           intent.relocation_id
                         ) do
                    Storage.locked(pool, fn ->
                      SourceSnapshots.create(
                        pool,
                        spec,
                        intent.relocation_id,
                        intent.source_epoch,
                        :clone
                      )
                    end)
                  end
                end
              )
            end
          )
        else
          snapshot
        end

      with {:ok, guid} <- captured do
        Storage.locked(pool, fn ->
          with {:ok, claim} <- ZFSDataset.snapshot_source(pool, spec),
               descriptor =
                 Map.put(intent, :stream, %{
                   source_dataset_guid: claim.dataset_guid,
                   to_guid: guid
                 }),
               wire = DiskTransfer.encode_descriptor(descriptor),
               :ok <-
                 Permit.issue(
                   config.transfer_state_dir,
                   pool,
                   wire,
                   command["public_key"],
                   command["revision"],
                   command["expires_at"]
                 ),
               do: {:ok, %{"descriptor" => wire}}
        end)
      end
    end
  end

  defp run(config, _, %{"kind" => "copy"} = command, intent) do
    with {:ok, descriptor} <- DiskTransfer.descriptor(command["descriptor"]),
         pool when not is_nil(pool) <- pool(config, intent.destination),
         {:ok, guid} <- receive_disk(config, pool, command, descriptor),
         do: {:ok, %{"dataset_guid" => guid}}
  end

  defp run(config, _, %{"kind" => "adopt"} = command, intent) do
    with {:ok, descriptor} <- DiskTransfer.descriptor(command["descriptor"]),
         pool when not is_nil(pool) <- pool(config, intent.destination),
         {:ok, spec} <- destination_spec(intent) do
      with {:ok, :adopted} <-
             Driver.with_transfer_import(config.execution, pool, spec, fn ->
               destination_owned(config, intent, fn ->
                 with :ok <- key_ready(config, intent),
                      :ok <-
                        if(CloneCopy.history?(pool, descriptor),
                          do: CloneCopy.adopt(pool, descriptor),
                          else: Disk.adopt(pool, descriptor)
                        ),
                      do: {:ok, :adopted}
               end)
             end),
           do: :ok
    end
  end

  defp run(config, _, %{"kind" => "revoke", "endpoint" => "source"}, intent),
    do:
      SourceExport.revoke(config.transfer_state_dir, intent.source.host_id, intent.relocation_id)

  defp run(config, _, %{"kind" => "revoke", "endpoint" => "destination"}, intent) do
    with :ok <-
           Key.retire(
             config.transfer_state_dir,
             intent.destination.host_id,
             intent.relocation_id,
             intent.destination.placement_id
           ),
         do: destination_owned(config, intent, fn -> :ok end)
  end

  defp run(config, _, %{"kind" => "discard"}, intent) do
    with pool when not is_nil(pool) <- pool(config, intent.destination),
         {:ok, spec} <- destination_spec(intent) do
      Driver.retire_transfer_destination(
        config.execution,
        pool,
        spec,
        intent.destination_epoch,
        fn ->
          destination_owned(config, intent, fn ->
            Storage.locked(pool, fn ->
              if CloneCopy.history?(pool, intent),
                do: CloneCopy.cleanup_intent(pool, intent),
                else: ImportCleanup.cleanup_intent(pool, intent)
            end)
          end)
        end
      )
    end
  end

  defp run(config, store, %{"kind" => "prune"}, intent) do
    with {:ok, current} <- source_command(store, intent),
         {:ok, spec} <- Executor.specification(current),
         pool when not is_nil(pool) <- pool(config, intent.source),
         :ok <-
           SourceExport.revoke(
             config.transfer_state_dir,
             intent.source.host_id,
             intent.relocation_id
           ) do
      Driver.with_transfer_source(
        config.execution,
        pool,
        spec,
        {current.execution_epoch, current.generation},
        if(current.kind in [:start, :provision], do: :running, else: :stopped),
        2000,
        fn ->
          Storage.locked(
            pool,
            fn ->
              case CloneCopy.release_source_mount(pool, intent) do
                :ok ->
                  SourceSnapshots.cleanup(
                    pool,
                    spec,
                    intent.relocation_id,
                    intent.source_epoch,
                    :clone
                  )

                _ ->
                  {:error, :clone_mount_unconfirmed}
              end
            end,
            2000
          )
        end
      )
    end
  end

  defp source_command(store, intent) do
    with {:ok, command} when is_map(command) <- Store.read(store, intent.source.placement_id),
         true <- command.vm_id == intent.vm_id and command.execution_epoch == intent.source_epoch,
         true <-
           command.host_id == intent.source.host_id and command.pool_id == intent.source.pool_id,
         true <-
           Map.take(command, Map.keys(intent.workload)) == DiskTransfer.source_workload(intent),
         do: {:ok, command},
         else: (_ -> {:error, :clone_source_unconfirmed})
  end

  # @cc [owner:ghuntley,label:recovery;security] clone-copy-mode-from-pool-identity
  # A same-host, same-pool clone MUST copy by block cloning (ADR-0145) and every
  # other clone MUST stream through a receive; adopt and discard follow the
  # durable copy history the copy left behind.
  defp receive_disk(config, pool, command, descriptor) when is_map(descriptor) do
    if CloneCopy.same_pool?(descriptor) do
      destination_owned(
        config,
        descriptor,
        fn ->
          with :ok <- key_ready(config, descriptor),
               do: CloneCopy.copy(pool, descriptor, command["descriptor"])
        end,
        false
      )
    else
      stream_disk(config, pool, command, descriptor)
    end
  end

  defp stream_disk(
         config,
         pool,
         command,
         %{source: %{host_id: host}, destination: %{host_id: host}} = descriptor
       ) do
    source_pool = pool(config, descriptor.source)

    destination_owned(
      config,
      descriptor,
      fn ->
        with :ok <- key_ready(config, descriptor),
             {:ok, journal} <-
               Storage.locked(pool, fn -> ReceivedDataset.prepare(pool, descriptor) end) do
          if journal["stream_state"] == "received" do
            receipt(pool, descriptor)
          else
            case receipt(pool, descriptor) do
              {:ok, guid} ->
                {:ok, guid}

              _ ->
                with {:ok, consumer, token} <-
                       Storage.locked(pool, fn -> local_receiver(pool, descriptor) end),
                     {:ok, producer} <-
                       Storage.locked(source_pool, fn ->
                         if token,
                           do:
                             SourceSnapshots.resume_export(
                               source_pool,
                               command["descriptor"],
                               token
                             ),
                           else: SourceSnapshots.export(source_pool, command["descriptor"])
                       end),
                     :ok <-
                       local_stream(
                         config,
                         descriptor,
                         command["public_key"],
                         producer,
                         consumer
                       ),
                     do: receipt(pool, descriptor)
            end
          end
        end
      end,
      false
    )
  end

  defp stream_disk(config, pool, command, _) do
    Receiver.pull(
      config.transfer_state_dir,
      pool,
      command["descriptor"],
      command["source_endpoint"],
      86_400_000,
      config.transfer_bytes_per_second
    )
  end

  defp local_receiver(pool, descriptor) do
    case ReceivedDataset.resume_token(pool, descriptor) do
      {:ok, token} ->
        with {:ok, receiver} <- ReceivedDataset.receiver(pool, descriptor),
             do: {:ok, receiver, token}

      _ ->
        with {:ok, receiver} <- ReceivedDataset.fresh_receiver(pool, descriptor),
             do: {:ok, receiver, nil}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] local-copy-obeys-source-lease
  # Bypassing SSH MUST NOT bypass source expiry/revocation. While receive ownership
  # is retained, re-read the exact native permit at least once a second. Identical
  # revisions never renew a monotonic deadline; newer revisions may extend it only
  # by their signed expiry delta. Cancellation or caller death kills the pipeline.
  defp local_stream(config, descriptor, public, producer, consumer) do
    with {:ok, lease} <- local_lease(config, descriptor, public, nil) do
      task =
        Task.async(fn ->
          Process.flag(:sensitive, true)

          Stream.run(
            stream_directory(config, descriptor),
            producer,
            consumer,
            86_400_000,
            config.local_transfer_bytes_per_second
          )
        end)

      try do
        await_local(task, config, descriptor, public, lease)
      catch
        :exit, _ -> {:error, :clone_stream_unconfirmed}
      after
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  defp await_local(task, config, descriptor, public, previous) do
    with {:ok, lease} <- local_lease(config, descriptor, public, previous) do
      case Task.yield(
             task,
             max(0, min(1000, lease.deadline - System.monotonic_time(:millisecond)))
           ) do
        {:ok, result} -> result
        nil -> await_local(task, config, descriptor, public, lease)
        _ -> {:error, :clone_stream_unconfirmed}
      end
    end
  end

  defp local_lease(config, descriptor, public, previous) do
    with {:ok, grant} <-
           PermitJournal.lookup(
             config.transfer_state_dir,
             descriptor.source.host_id,
             descriptor.relocation_id,
             public,
             System.system_time(:second)
           ),
         true <- grant.descriptor == descriptor do
      now = System.monotonic_time(:millisecond)
      wall = now + (grant.expires_at - System.system_time(:second)) * 1000

      deadline =
        cond do
          previous == nil ->
            min(wall, now + 300_000)

          grant.revision == previous.revision and grant.expires_at == previous.expires_at ->
            previous.deadline

          grant.revision > previous.revision and grant.expires_at >= previous.expires_at ->
            min(wall, previous.deadline + (grant.expires_at - previous.expires_at) * 1000)

          true ->
            now
        end

      if deadline > now,
        do: {:ok, Map.put(grant, :deadline, deadline)},
        else: {:error, :clone_lease_unconfirmed}
    else
      _ -> {:error, :clone_lease_unconfirmed}
    end
  end

  defp key_ready(config, intent),
    do:
      Key.ready(
        config.transfer_state_dir,
        intent.destination.host_id,
        intent.relocation_id,
        intent.destination.placement_id
      )

  defp receipt(pool, descriptor) do
    Storage.locked(pool, fn ->
      with {:ok, journal} <- ReceivedDataset.verify(pool, descriptor),
           do: {:ok, journal["dataset_guid"]}
    end)
  end

  defp destination_spec(intent),
    do:
      intent.workload
      |> Map.drop([:architecture])
      |> Map.merge(%{id: intent.destination.placement_id, pool_id: intent.destination.pool_id})
      |> Spec.new()

  defp pool(config, endpoint),
    do: Enum.find(config.pools, &(&1.id == endpoint.pool_id and &1.host_id == endpoint.host_id))

  defp ssh_request(intent),
    do: %{
      host_id: intent.destination.host_id,
      relocation_id: intent.relocation_id,
      placement_id: intent.destination.placement_id,
      source_host_id: intent.source.host_id
    }

  defp stream_directory(config, intent),
    do: Path.join([config.transfer_state_dir, "transfers", intent.relocation_id, "stream"])

  defp destination_owned(config, intent, fun, stream_lock \\ true) do
    directory = stream_directory(config, intent)

    owned(Path.join(Path.dirname(directory), "receive"), fn ->
      if stream_lock, do: owned(directory, fun), else: fun.()
    end)
  end

  defp owned(directory, fun) do
    with :ok <- PrivateFiles.directory(directory), {:ok, lock} <- Lock.acquire(directory) do
      try do
        fun.()
      after
        Lock.release(lock)
      end
    end
  end
end
