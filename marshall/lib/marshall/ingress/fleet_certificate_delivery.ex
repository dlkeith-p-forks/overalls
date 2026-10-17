defmodule Marshall.Ingress.FleetCertificateDelivery do
  @moduledoc "Purpose-bound delivery and audited installation acknowledgement for gateways."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.{Error, FleetCertificate, FleetCertificateInstallation, Services}
  require Ash.Query
  require Marshall.Events

  @impl true
  def run(input, options, %{actor: %SystemActor{purpose: :compute}}) do
    result =
      Ledger.transaction(fn ->
        case options[:operation] do
          :deliver -> deliver!(input.arguments.service_token)
          :acknowledge -> acknowledge!(input.arguments)
        end
      end)
      |> Error.result()

    case {options[:operation], result} do
      {:acknowledge, {:ok, %{host_id: host, generation: generation, newly_installed: true}}} ->
        Marshall.Events.emit("ingress.fleet_certificate_installed",
          host_id: host,
          generation: generation
        )

      _ ->
        :ok
    end

    case result do
      {:ok, %{newly_installed: _} = receipt} -> {:ok, Map.delete(receipt, :newly_installed)}
      other -> other
    end
  rescue
    _ -> {:error, Error.exception(reason: :unavailable)}
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:security] fleet-wildcard-secret-delivery
  # Only a current gateway credential may receive the active exact-zone
  # certificate. Decryption MUST occur after role authentication and remain
  # inside the HTTPS response; no secret may enter jobs, logs or audit rows.
  defp deliver!(token) do
    service = Services.authenticate!(token)

    unless service.role == :gateway and is_binary(service.host_id),
      do: Ledger.rollback(:unauthorized)

    zone = Application.get_env(:marshall, :ingress_zone)
    now = Ledger.now()

    certificate =
      FleetCertificate
      |> Ash.Query.filter(zone == ^zone and status == :active and expires_at > ^now)
      |> Ash.Query.sort(generation: :desc)
      |> Ash.read_one!(actor: SystemActor.compute())

    unless certificate, do: Ledger.rollback(:unavailable)

    loaded = Ash.load!(certificate, [:chain_pem, :private_key_pem], actor: SystemActor.compute())

    unless is_binary(loaded.chain_pem) and is_binary(loaded.private_key_pem),
      do: Ledger.rollback(:unavailable)

    %{
      host_id: service.host_id,
      zone: zone,
      generation: certificate.generation,
      fingerprint: certificate.fingerprint,
      expires_at: DateTime.to_iso8601(certificate.expires_at),
      chain_pem: loaded.chain_pem,
      private_key_pem: loaded.private_key_pem
    }
  end

  # @cc [owner:ghuntley,label:security;recovery] fleet-wildcard-install-audit
  # An acknowledgement MUST bind the current service generation, host and exact
  # issued certificate fingerprint. Retries for the same host/generation are
  # idempotent. A newer generation of the same gateway service may rebind the
  # exact certificate after credential rotation; conflicting bytes or an older
  # service generation cannot replace the current acknowledgement.
  defp acknowledge!(request) do
    service = Services.authenticate!(request.service_token)

    unless service.role == :gateway and is_binary(service.host_id),
      do: Ledger.rollback(:unauthorized)

    zone = Application.get_env(:marshall, :ingress_zone)

    case Ledger.read!(FleetCertificate, generation: request.generation, zone: zone) do
      [%{status: :active, fingerprint: fingerprint, expires_at: expires}]
      when fingerprint == request.fingerprint ->
        unless DateTime.compare(expires, Ledger.now()) == :gt,
          do: Ledger.rollback(:invalid_binding)

        :ok

      _ ->
        Ledger.rollback(:invalid_binding)
    end

    Marshall.Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["fleet-install:#{service.host_id}:#{zone}:#{request.generation}"]
    )

    created? =
      case Ledger.read!(FleetCertificateInstallation,
             host_id: service.host_id,
             zone: zone,
             generation: request.generation
           ) do
        [] ->
          Ledger.create!(FleetCertificateInstallation, :record, %{
            host_id: service.host_id,
            service_id: service.id,
            service_generation: service.generation,
            zone: zone,
            generation: request.generation,
            fingerprint: request.fingerprint
          })

          true

        [%{fingerprint: fingerprint, service_id: id, service_generation: generation}]
        when fingerprint == request.fingerprint and id == service.id and
               generation == service.generation ->
          false

        [%{fingerprint: fingerprint, service_id: id, service_generation: generation} = installed]
        when fingerprint == request.fingerprint and id == service.id and
               generation < service.generation ->
          Ledger.update!(installed, :rebind_service, %{
            service_generation: service.generation
          })

          true

        _ ->
          Ledger.rollback(:invalid_binding)
      end

    %{host_id: service.host_id, generation: request.generation, newly_installed: created?}
  end
end
