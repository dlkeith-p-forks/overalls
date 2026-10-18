defmodule Lilly.Transfer.Receiver do
  @moduledoc "Serialized destination preparation, native SSH receive and verified staging receipt."
  require Lilly.Events
  alias OverallsProtocol.DiskTransfer, as: Relocation
  alias Lilly.Host.{Lock, Pool, PrivateFiles, Storage}
  alias Lilly.Transfer.{Key, ReceivedDataset, SSH}

  # @cc [owner:ghuntley,label:security;recovery] receiver-pipeline-keeps-import-only-authority
  # pull/5 requires authenticated descriptor/endpoint distribution, a current
  # reservation and source permit, and no held host/pool lock. It MUST serialize
  # the entire receive attempt per relocation, persist local intent before bytes,
  # stream outside the pool lock, and verify native receipt under both stream and
  # pool locks. Identical received retries MUST verify without streaming again.
  # Returned local GUID is staging evidence only, never activation or released
  # source/capacity authority. Callers MUST stop the task and prove quiescence
  # before cleanup or adoption, using the same activity and stream locks.
  # Cached connection paths MUST be revalidated after acquiring activity ownership;
  # a cancelled key MUST reject delayed work before any receive preparation.
  # Quiescent completed native state MUST recover a lost receipt without replay.
  # Partial state MUST use a locally verified token and source-validated resume;
  # ordinary replay requires independently proven fresh native absence.
  # Every receive attempt MUST apply the validated positive operator byte rate.
  @spec pull(Path.t(), Pool.t(), map(), map(), pos_integer()) ::
          {:ok, String.t()} | {:error, atom()}
  @spec pull(Path.t(), Pool.t(), map(), map(), pos_integer(), pos_integer()) ::
          {:ok, String.t()} | {:error, atom()}
  @spec pull(Path.t(), Pool.t(), map(), map(), pos_integer(), pos_integer(), pid() | nil) ::
          {:ok, String.t()} | {:error, atom()}
  def pull(root, pool, wire, endpoint, timeout, rate \\ 67_108_864, progress \\ nil) do
    with {:ok, guid} <- pull_disk(root, pool, wire, endpoint, timeout, rate, progress),
         :ok <-
           Lilly.Transfer.CheckpointTransfer.pull(
             root,
             pool,
             wire,
             endpoint,
             timeout,
             rate,
             progress
           ),
         do: {:ok, guid}
  end

  defp pull_disk(root, pool, wire, endpoint, timeout, rate, progress) do
    with true <- is_nil(Lock.current()) and is_integer(timeout) and timeout in 1000..86_400_000,
         true <- is_integer(rate) and rate in 1..1_073_741_824,
         true <- is_nil(progress) or is_pid(progress),
         {:ok, descriptor} <- Relocation.descriptor(wire),
         true <-
           descriptor.destination.host_id == pool.host_id and
             descriptor.destination.pool_id == pool.id,
         {:ok, files} <-
           Key.connection(
             root,
             pool.host_id,
             descriptor.relocation_id,
             descriptor.destination.placement_id,
             descriptor.source.host_id,
             endpoint
           ) do
      activity = Path.join(Path.dirname(files.stream_dir), "receive")

      owned(activity, fn ->
        with {:ok, ^files} <-
               Key.connection(
                 root,
                 pool.host_id,
                 descriptor.relocation_id,
                 descriptor.destination.placement_id,
                 descriptor.source.host_id,
                 endpoint
               ) do
          case guarded(files.stream_dir, pool, fn -> prepare(pool, descriptor) end) do
            {:received, guid} ->
              {:ok, guid}

            {:receive, consumer, token} ->
              request = %{
                host_id: pool.host_id,
                source_host_id: descriptor.source.host_id,
                relocation_id: descriptor.relocation_id,
                placement_id: descriptor.destination.placement_id
              }

              # The linked child inherits no pool/activity helper in its process
              # dictionary. Its native helper owns the separate stream lock and is
              # revoked if this attempt dies. The parent retains activity exclusion.
              receiver = self()

              task =
                Task.async(fn ->
                  Process.flag(:sensitive, true)

                  SSH.pull(
                    root,
                    request,
                    endpoint,
                    consumer,
                    timeout,
                    token,
                    rate,
                    if(is_pid(progress), do: receiver, else: nil)
                  )
                end)

              result =
                try do
                  await_stream(
                    task,
                    System.monotonic_time(:millisecond) + timeout + 10_000,
                    progress
                  )
                catch
                  :exit, _ -> {:error, :receive_stream_unconfirmed}
                after
                  Task.shutdown(task, :brutal_kill)
                end

              with :ok <- result do
                guarded(files.stream_dir, pool, fn -> receipt(pool, descriptor) end)
              end

            error ->
              error
          end
        end
      end)
    else
      _ -> {:error, :receive_authority_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:protocol] receive-progress-is-attempt-scoped
  # Only this linked stream task's counters may be forwarded, tagged with the
  # receiver attempt PID. Progress MUST NOT renew deadlines or become a receipt.
  # Waiting uses the original absolute deadline even while updates arrive.
  defp await_stream(%Task{pid: pid, ref: ref} = task, deadline, progress) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :receive_stream_unconfirmed}
    else
      receive do
        {:lilly_transfer_progress, ^pid, count}
        when is_pid(progress) and is_integer(count) and count in 0..9_223_372_036_854_775_807 ->
          send(progress, {:lilly_transfer_progress, self(), count})
          await_stream(task, deadline, progress)

        {^ref, result} ->
          # The enclosing Task.shutdown/2 owns monitor/alias cleanup as well as
          # any still-live child; do not inspect Task's opaque monitor reference.
          result

        {:DOWN, ^ref, :process, ^pid, _} ->
          {:error, :receive_stream_unconfirmed}
      after
        max(0, deadline - System.monotonic_time(:millisecond)) ->
          {:error, :receive_stream_unconfirmed}
      end
    end
  end

  defp prepare(pool, descriptor) do
    case ReceivedDataset.prepare(pool, descriptor) do
      {:ok, %{"stream_state" => "received"}} ->
        case receipt(pool, descriptor) do
          {:ok, guid} -> {:received, guid}
          error -> error
        end

      {:ok, %{"stream_state" => "receiving"}} ->
        case receipt(pool, descriptor) do
          {:ok, guid} -> {:received, guid}
          _ -> transfer(pool, descriptor)
        end

      error ->
        error
    end
  end

  defp transfer(pool, descriptor) do
    case ReceivedDataset.resume_token(pool, descriptor) do
      {:ok, token} ->
        with {:ok, command} <- ReceivedDataset.receiver(pool, descriptor),
             do: {:receive, command, token}

      _ ->
        with {:ok, command} <- ReceivedDataset.fresh_receiver(pool, descriptor),
             do: {:receive, command, nil}
    end
  end

  # @cc [owner:ghuntley,label:security;observability] receive-receipt-event-correlated
  # A verified native receive receipt MUST report only the relocation and
  # destination placement identifiers; dataset GUIDs, endpoints, paths and
  # credentials MUST NOT be logged. Re-verification of an already received
  # dataset MAY repeat the event until control acknowledges the receipt.
  defp receipt(pool, descriptor) do
    with {:ok, journal} <- ReceivedDataset.verify(pool, descriptor) do
      Lilly.Events.emit("lilly.transfer_received",
        relocation_id: descriptor.relocation_id,
        placement_id: descriptor.destination.placement_id
      )

      {:ok, journal["dataset_guid"]}
    end
  end

  # @cc [owner:ghuntley,label:recovery] receiver-pool-contention-window
  # Preparation and receipt may retry pool ownership for two seconds while
  # retaining receive/stream exclusion. They MUST NOT repeat a protected effect;
  # caller death and lease fencing still cancel the owning receive task.
  defp guarded(stream, pool, fun), do: owned(stream, fn -> Storage.locked(pool, fun, 2000) end)

  defp owned(directory, fun) do
    with :ok <- PrivateFiles.directory(directory), {:ok, lock} <- Lock.acquire(directory) do
      try do
        result = fun.()

        case Lock.release(lock) do
          :ok -> result
          _ -> {:error, :receive_quiescence_unconfirmed}
        end
      after
        if Lock.held?(lock), do: Lock.release(lock)
      end
    else
      _ -> {:error, :receive_busy}
    end
  end
end
