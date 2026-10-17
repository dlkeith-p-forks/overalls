defmodule Audi.TLS.Installation do
  @moduledoc "Prove the in-memory fleet certificate on the local listener before route readiness."
  alias Audi.TLS.{Probe, Store}
  require Audi.Events

  # @cc [owner:ghuntley,label:security] audi-readiness-report-after-probe
  # Readiness MUST select the validated fleet wildcard from memory and prove a
  # local verified TLS handshake before sending current execution and derived
  # certificate metadata: either this job's own probe, or the fleet worker's
  # probe of the exact installed generation (Store.proven?/2). Peer addresses
  # and route lifetime MUST come from Marshall, never this caller. Failed probes
  # MUST send no route report.
  @spec publish_fleet(Audi.Control.Client.t(), GenServer.server(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def publish_fleet(client, store, binding, options) do
    hostname = binding.label <> "." <> Keyword.fetch!(options, :zone)

    with {:ok, metadata} <- Store.fleet_metadata(store, hostname),
         :ok <-
           if(Store.proven?(store, metadata.generation),
             do: :ok,
             else:
               probe(
                 Keyword.fetch!(options, :probe_peer),
                 metadata,
                 Keyword.fetch!(options, :trust_pem)
               )
           ),
         request =
           Map.take(binding, [
             :vm_id,
             :placement_id,
             :execution_epoch,
             :generation,
             :service_generation
           ])
           |> Map.merge(%{
             certificate_fingerprint: metadata.fingerprint,
             certificate_expires_at:
               DateTime.from_unix!(metadata.expires_at) |> DateTime.to_iso8601()
           }),
         {:ok, result} <- Audi.Control.Client.report_ready_route(client, request) do
      {:ok, result}
    end
  end

  defp probe(peer, metadata, roots) do
    case Probe.check(peer, metadata, roots) do
      :ok ->
        :ok

      {:error, reason} ->
        Audi.Events.emit("audi.certificate_install_rejected", reason: :probe_failed)
        {:error, reason}
    end
  end
end
