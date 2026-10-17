defmodule Lilly.Transfer.DestinationCleanup do
  @moduledoc "Fenced reclamation of a cancelled destination from local import history."
  require Lilly.Events
  alias OverallsProtocol.Relocation
  alias Lilly.Host.Lock
  alias Lilly.Transfer.Key
  alias Lilly.VM.{Disk, Driver, Spec}

  # @cc [owner:ghuntley,label:security;recovery] destination-cleanup-independent-of-source-restoration
  # execute/3 requires authenticated pre-handoff cancellation. It MUST validate
  # the immutable intent, enrolled destination and bounded lease before effects,
  # permanently retire the key, and fence never-activated destination execution.
  # Under placement, receive, stream and pool exclusion it MUST reclaim only
  # locally proven import ownership. Missing history permits absence checks only.
  # Expired, busy or ambiguous effects MUST retain fences and return unconfirmed.
  # A receipt proves destination reclamation only, never source restoration or
  # permission to release reservations. No remote stream GUID or image is required.
  @spec execute(Lilly.Control.Config.t(), map(), pos_integer()) ::
          {:ok, %{id: String.t(), placement_id: String.t(), execution_epoch: pos_integer()}}
          | {:error, :destination_cleanup_unconfirmed}
  def execute(config, wire, expires) do
    with true <- is_nil(Lock.current()),
         {:ok, intent} <- Relocation.intent(wire) do
      authorized(config, intent, expires)
    else
      _ -> failure()
    end
  end

  defp authorized(config, intent, expires) do
    with true <- intent.destination.host_id == config.client.host_id,
         :ok <- lease(expires),
         true <- is_binary(config.transfer_state_dir),
         pool when not is_nil(pool) <-
           Enum.find(config.pools, fn pool ->
             pool.id == intent.destination.pool_id and pool.host_id == intent.destination.host_id
           end),
         {:ok, spec} <-
           intent.workload
           |> Map.drop([:architecture])
           |> Map.merge(%{id: intent.destination.placement_id, pool_id: pool.id})
           |> Spec.new(),
         :ok <- Key.retire(config.transfer_state_dir, pool.host_id, intent.relocation_id, spec.id),
         base = Path.join([config.transfer_state_dir, "transfers", intent.relocation_id]),
         :ok <-
           Driver.retire_transfer_destination(
             config.execution,
             pool,
             spec,
             intent.destination_epoch,
             fn ->
               owned(Path.join(base, "receive"), fn ->
                 owned(Path.join(base, "stream"), fn ->
                   with :ok <- lease(expires),
                        :ok <-
                          Key.retire(
                            config.transfer_state_dir,
                            pool.host_id,
                            intent.relocation_id,
                            spec.id
                          ),
                        :ok <- Disk.discard_import_intent(pool, intent),
                        do: lease(expires)
                 end)
               end)
             end
           ),
         do: completed(intent),
         else: (_ -> unconfirmed(intent))
  end

  # @cc [owner:ghuntley,label:security;observability] destination-cleanup-outcome-events
  # Reclamation outcomes MUST report only the relocation and destination
  # placement identifiers plus the closed reason atom; intents, workloads and
  # endpoints MUST NOT be logged. Unparsed intents carry no event because no
  # identifiers are trustworthy yet. Rejections MAY repeat per bounded lease
  # retry; the owning runtime keeps its own deduplicated diagnostic.
  defp completed(intent) do
    Lilly.Events.emit("lilly.cleanup_completed",
      relocation_id: intent.relocation_id,
      placement_id: intent.destination.placement_id
    )

    {:ok,
     %{
       id: intent.relocation_id,
       placement_id: intent.destination.placement_id,
       execution_epoch: intent.destination_epoch
     }}
  end

  defp unconfirmed(intent) do
    Lilly.Events.emit("lilly.cleanup_unconfirmed",
      relocation_id: intent.relocation_id,
      placement_id: intent.destination.placement_id,
      reason: :destination_cleanup_unconfirmed
    )

    failure()
  end

  defp owned(directory, fun) do
    with {:ok, lock} <- Lock.acquire(directory) do
      try do
        result = fun.()
        with :ok <- Lock.release(lock), do: result
      after
        if Lock.held?(lock), do: Lock.release(lock)
      end
    end
  end

  defp lease(expires) do
    if is_integer(expires) and (expires - System.system_time(:second)) in 1..300,
      do: :ok,
      else: failure()
  end

  defp failure, do: {:error, :destination_cleanup_unconfirmed}
end
