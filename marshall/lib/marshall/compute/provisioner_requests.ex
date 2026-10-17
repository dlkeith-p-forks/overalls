defmodule Marshall.Compute.ProvisionerRequests do
  @moduledoc """
  Lilly's closed control requests over the control WebSocket (ADR-0142).

  Each route validates its decoded document with the closed `OverallsProtocol`
  decoder and calls the unchanged domain exchange with the host credential,
  which every exchange authenticates again under the host lock. Session and
  epoch fencing travel in the documents, as before.
  """

  alias Marshall.Compute.ProvisionerControl

  @routes %{
    "sessions" => {OverallsProtocol.Execution, :session, ProvisionerControl, :open_execution},
    "exchange" =>
      {OverallsProtocol.Execution, :exchange, ProvisionerControl, :exchange_execution},
    "inception" =>
      {OverallsProtocol.InceptionControl, :request, Marshall.Ingress.EnvironmentPublications,
       :exchange},
    "clone" =>
      {OverallsProtocol.CloneControl, :exchange, Marshall.Compute.CloneEffects, :exchange},
    "relocation_keys" =>
      {OverallsProtocol.RelocationKeys, :exchange, Marshall.Compute.RelocationKeys, :exchange},
    "relocation_probe" =>
      {OverallsProtocol.RelocationProbe, :exchange, Marshall.Compute.RelocationProbes, :exchange},
    "relocation_source" =>
      {OverallsProtocol.RelocationSource, :exchange, Marshall.Compute.RelocationSources,
       :exchange},
    "relocation_readiness" =>
      {OverallsProtocol.RelocationReadiness, :exchange, Marshall.Compute.RelocationReadiness,
       :exchange},
    "relocation_revocation" =>
      {OverallsProtocol.RelocationRevocation, :exchange, Marshall.Compute.RelocationRevocations,
       :exchange},
    "relocation_destination_revocation" =>
      {OverallsProtocol.RelocationDestinationRevocation, :exchange,
       Marshall.Compute.RelocationDestinationRevocations, :exchange},
    "relocation_destination_cleanup" =>
      {OverallsProtocol.RelocationDestinationCleanup, :exchange,
       Marshall.Compute.RelocationDestinationCleanups, :exchange},
    "relocation_snapshot_cleanup" =>
      {OverallsProtocol.RelocationSnapshotCleanup, :exchange,
       Marshall.Compute.RelocationSnapshotCleanups, :exchange},
    "relocation_key_retirement" =>
      {OverallsProtocol.RelocationKeyRetirement, :exchange,
       Marshall.Compute.RelocationKeyRetirement, :exchange},
    "relocation_cleanup" =>
      {OverallsProtocol.RelocationCleanup, :exchange, Marshall.Compute.RelocationCleanup,
       :exchange},
    "relocation_import" =>
      {OverallsProtocol.RelocationImport, :exchange, Marshall.Compute.RelocationImports,
       :exchange},
    "relocation_receive" =>
      {OverallsProtocol.RelocationReceive, :exchange, Marshall.Compute.RelocationReceives,
       :exchange}
  }

  @doc "The routes both transports serve."
  @spec routes() :: [String.t()]
  def routes, do: Map.keys(@routes)

  @doc """
  Handles one decoded request document for `route` with the host credential.
  Unknown routes are refused as an unsupported version, as before.
  """
  @spec handle(String.t(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def handle(route, token, json) when is_map_key(@routes, route), do: call(route, token, json)
  def handle(_route, _token, _json), do: {:error, :unsupported_version}

  @spec call(String.t(), binary(), map()) :: {:ok, map()} | {:error, term()}
  defp call(route, token, json) do
    {protocol, decoder, domain, exchange} = Map.fetch!(@routes, route)

    with {:ok, message} <- apply(protocol, decoder, [json]),
         do: apply(domain, exchange, [token, message])
  end
end
