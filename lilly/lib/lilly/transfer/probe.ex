defmodule Lilly.Transfer.Probe do
  @moduledoc "Authenticated probe effects joined to local source authority and destination keys."
  alias OverallsProtocol.{Relocation, RelocationProbe}
  alias Lilly.Control.{Config, Store}
  alias Lilly.Transfer.{Key, PermitJournal, SSH}
  alias Lilly.VM.{Driver, Executor}

  # @cc [owner:ghuntley,label:security;recovery] probe-effects-preserve-running-source
  # execute/3 requires the authenticated control runtime and its host-owned store.
  # Source grants MUST match retained running execution and the exact local driver
  # claim under its placement lock. They MUST NOT create snapshots or stop a VM.
  # Destination probes MUST use the existing relocation key and enrolled pin.
  # Both phases MUST reject expired or overlong leases before effects and before
  # returning a receipt. A grant receipt MUST NOT assert connectivity.
  @spec execute(Config.t(), Store.t(), RelocationProbe.command()) ::
          {:ok, RelocationProbe.result()} | {:error, atom()}
  def execute(config, store, request) do
    with {:ok, ^request} <- RelocationProbe.command(RelocationProbe.encode_command(request)),
         true <- store.host_id == config.client.host_id and is_binary(config.transfer_state_dir),
         :ok <- lease(request),
         :ok <- perform(config, store, request),
         :ok <- lease(request) do
      {:ok, Map.take(request, [:id, :phase, :challenge, :revision, :expires_at])}
    else
      _ -> {:error, :probe_unconfirmed}
    end
  end

  defp perform(config, store, %{phase: :grant} = request) do
    with true <- config.client.host_id == request.intent.source.host_id,
         {:ok, command} <- current(store, request),
         {:ok, spec} <- Executor.specification(command),
         pool when not is_nil(pool) <-
           Enum.find(config.pools, &(&1.id == request.intent.source.pool_id)),
         {:ok, :granted} <-
           Driver.with_transfer_source(
             config.execution,
             pool,
             spec,
             {request.intent.source_epoch, request.generation},
             :running,
             fn ->
               with {:ok, ^command} <- current(store, request),
                    :ok <- lease(request),
                    :ok <-
                      PermitJournal.probe(
                        config.transfer_state_dir,
                        Relocation.encode_intent(request.intent),
                        request.public_key,
                        request.challenge,
                        request.revision,
                        request.expires_at,
                        System.system_time(:second)
                      ) do
                 {:ok, :granted}
               else
                 _ -> {:error, :probe_unconfirmed}
               end
             end
           ) do
      :ok
    else
      _ -> {:error, :probe_unconfirmed}
    end
  end

  defp perform(config, _store, %{phase: :probe} = request) do
    if config.client.host_id == request.intent.destination.host_id do
      ssh_request = %{
        host_id: config.client.host_id,
        source_host_id: request.intent.source.host_id,
        relocation_id: request.intent.relocation_id,
        placement_id: request.intent.destination.placement_id
      }

      remaining = request.expires_at - System.system_time(:second)

      with {:ok, files} <-
             Key.connection(
               config.transfer_state_dir,
               ssh_request.host_id,
               ssh_request.relocation_id,
               ssh_request.placement_id,
               ssh_request.source_host_id,
               request.source_endpoint
             ),
           true <- files.public_key == request.public_key do
        SSH.probe(
          config.transfer_state_dir,
          ssh_request,
          request.source_endpoint,
          request.challenge,
          min(30_000, remaining * 1000)
        )
      else
        _ -> {:error, :probe_unconfirmed}
      end
    else
      {:error, :probe_unconfirmed}
    end
  end

  defp current(store, request) do
    intent = request.intent

    with {:ok, command} when is_map(command) <- Store.read(store, intent.source.placement_id),
         true <-
           command.vm_id == intent.vm_id and command.host_id == intent.source.host_id and
             command.pool_id == intent.source.pool_id and
             command.execution_epoch == intent.source_epoch and
             command.generation == request.generation and command.kind in [:start, :provision],
         true <- Map.take(command, Map.keys(intent.workload)) == intent.workload,
         do: {:ok, command},
         else: (_ -> {:error, :probe_unconfirmed})
  end

  defp lease(request) do
    if (request.expires_at - System.system_time(:second)) in 1..300,
      do: :ok,
      else: {:error, :probe_unconfirmed}
  end
end
