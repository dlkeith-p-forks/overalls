defmodule Lilly.Transfer.ReadinessProbe do
  @moduledoc "Guest readiness under the retained destination activation command."
  require Lilly.Events
  alias Lilly.Control.{Config, Store}
  alias Lilly.VM.{Driver, Executor}
  alias OverallsProtocol.RelocationReadiness

  # @cc [owner:ghuntley,label:security;recovery] readiness-probe-current-store-and-boot
  # execute/3 MUST match the activation ID, logical VM, placement, epoch, generation
  # and shape to the host's retained start command before and after probing. Driver
  # readiness MUST verify its local boot challenge and confinement on both sides
  # of the wait. Receipt contains only the verified guest boot ID, never a challenge.
  # Placement-lock contention and guest timeout MUST retain their bounded reason
  # atoms for the effect runtime's deduplicated diagnostic; neither is a receipt.
  @spec execute(Config.t(), Store.t(), RelocationReadiness.command()) ::
          {:ok, String.t()} | {:error, atom()}
  def execute(config, store, request) do
    with {:ok, ^request} <-
           RelocationReadiness.command(RelocationReadiness.encode_command(request)),
         true <- (request.expires_at - System.system_time(:second)) in 1..300,
         true <-
           request.descriptor.destination.host_id == config.client.host_id and
             store.host_id == config.client.host_id,
         true <- Lilly.Private.Readiness.ready?(config.execution.network),
         {:ok, command} <- current(store, request),
         {:ok, spec} <- Executor.specification(command),
         pool when not is_nil(pool) <- Enum.find(config.pools, &(&1.id == command.pool_id)),
         {:ok, boot_id} <-
           Driver.ready_boot(config.execution, pool, spec,
             execution_epoch: command.execution_epoch,
             generation: command.generation,
             timeout: request.timeout_ms
           ),
         {:ok, ^command} <- current(store, request),
         true <- Lilly.Private.Readiness.ready?(config.execution.network),
         do: probed(request, boot_id),
         else: (
           {:error, reason} when reason in [:execution_unavailable, :readiness_timeout] ->
             {:error, reason}

           _ ->
             {:error, :readiness_unconfirmed}
         )
  end

  # @cc [owner:ghuntley,label:security;observability] readiness-event-correlated
  # A completed probe MUST report only the relocation, destination placement and
  # activation generation; boot identifiers, challenges, descriptors and guest
  # output MUST NOT be logged. Re-probing an unacknowledged command MAY repeat
  # the event. Rejections stay deduplicated runtime diagnostics.
  defp probed(request, boot_id) do
    Lilly.Events.emit("lilly.readiness_probed",
      relocation_id: request.descriptor.relocation_id,
      placement_id: request.descriptor.destination.placement_id,
      generation: request.generation
    )

    {:ok, boot_id}
  end

  defp current(store, request) do
    descriptor = request.descriptor

    with {:ok, command} when is_map(command) <-
           Store.read(store, descriptor.destination.placement_id),
         true <-
           command.id == request.id and command.kind == :start and
             command.vm_id == descriptor.vm_id and
             command.host_id == descriptor.destination.host_id and
             command.pool_id == descriptor.destination.pool_id and
             command.placement_id == descriptor.destination.placement_id and
             command.execution_epoch == descriptor.destination_epoch and
             command.generation == request.generation and
             Map.take(command, Map.keys(descriptor.workload)) == descriptor.workload,
         do: {:ok, command},
         else: (_ -> {:error, :readiness_unconfirmed})
  end
end
