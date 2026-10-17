defmodule Marshall.Ingress.Routes do
  @moduledoc "Internal transaction boundary for authenticated gateway readiness reports."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger

  alias Marshall.Ingress.{
    Endpoint,
    Error,
    Execution,
    FleetCertificate,
    FleetCertificateInstallation,
    Route,
    Service,
    Services
  }

  require Ash.Query

  # @cc [owner:ghuntley,label:security;concurrency] ingress-route-execution-binding
  # Report admission MUST lock service, host, VM and route in that order. The
  # report MUST match current service generation and running execution exactly,
  # with fresh host evidence, relocation readiness, registered key and addresses.
  # Certificate metadata is an authenticated infrastructure attestation, not
  # independent certificate proof. The gateway producer MUST validate and install
  # matching TLS material and verify the local SNI listener before reporting.
  @impl true
  def run(input, options, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn -> perform(options[:operation], input.arguments) end) |> Error.result()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  defp perform(:report, request), do: report!(request)
  defp perform(:current, request), do: current!(request.label)

  defp report!(request) do
    service = Services.authenticate!(request.service_token)

    {vm, host, now} = Execution.current!(service, request, :exclusive)

    endpoint = List.first(Ledger.read!(Endpoint, vm_id: vm.id)) || deny!()

    unless Regex.match?(~r/\A[0-9a-f]{64}\z/, request.certificate_fingerprint) and
             DateTime.compare(request.certificate_expires_at, now) == :gt,
           do: deny!()

    zone = Application.get_env(:marshall, :ingress_zone)
    active = List.first(Ledger.read!(FleetCertificate, zone: zone, status: :active)) || deny!()

    acknowledgement =
      List.first(
        Ledger.read!(FleetCertificateInstallation,
          host_id: service.host_id,
          zone: zone,
          generation: active.generation
        )
      ) || deny!()

    unless request.certificate_fingerprint == active.fingerprint and
             DateTime.compare(request.certificate_expires_at, active.expires_at) == :eq and
             DateTime.compare(active.expires_at, now) == :gt and
             acknowledgement.service_id == service.id and
             acknowledgement.service_generation == service.generation and
             acknowledgement.fingerprint == active.fingerprint,
           do: deny!()

    existing =
      Route
      |> Ash.Query.filter(vm_id == ^vm.id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(actor: SystemActor.compute())

    expiry =
      Enum.min_by(
        [DateTime.add(now, 5, :second), request.certificate_expires_at],
        &DateTime.to_unix(&1, :microsecond)
      )

    values =
      Map.take(request, [
        :placement_id,
        :service_generation,
        :execution_epoch,
        :generation,
        :certificate_fingerprint,
        :certificate_expires_at
      ])
      |> Map.merge(%{
        host_id: host.id,
        service_id: service.id,
        revision: if(existing, do: existing.revision + 1, else: 1),
        expires_at: expiry
      })

    route =
      cond do
        is_nil(existing) ->
          Ledger.create!(Route, :record, Map.put(values, :vm_id, vm.id))

        Map.take(existing, Map.keys(Map.drop(values, [:expires_at, :revision]))) ==
            Map.drop(values, [:expires_at, :revision]) ->
          Ledger.update!(existing, :refresh, Map.take(values, [:expires_at, :revision]))

        true ->
          Ledger.update!(existing, :replace, values)
      end

    %{
      id: route.id,
      revision: route.revision,
      label: endpoint.label,
      expires_at: route.expires_at,
      certificate_fingerprint: route.certificate_fingerprint
    }
  end

  # @cc [owner:ghuntley,label:security;concurrency] ingress-current-route-projection
  # Reads MUST revalidate live gateway generation, execution and report/certificate
  # expiry under service -> host -> VM -> route locks. Addresses and SSH keys MUST
  # come from that current gateway. Raw stored reports MUST NOT substitute for
  # this projection, and a projection MUST NOT grant end-user application access.
  defp current!(label) do
    unless OverallsProtocol.IngressName.valid_label?(label), do: deny!()
    endpoint = List.first(Ledger.read!(Endpoint, label: label)) || deny!()
    candidate = List.first(Ledger.read!(Route, vm_id: endpoint.vm_id)) || deny!()
    service = shared!(Service, id: candidate.service_id)
    {_vm, _host, _now} = Execution.current!(service, candidate, :shared)
    route = shared!(Route, id: candidate.id)

    binding = [
      :vm_id,
      :host_id,
      :placement_id,
      :execution_epoch,
      :generation,
      :service_id,
      :service_generation
    ]

    unless Map.take(route, binding) == Map.take(candidate, binding), do: deny!()
    now = Ledger.now()

    zone = Application.get_env(:marshall, :ingress_zone)
    active = List.first(Ledger.read!(FleetCertificate, zone: zone, status: :active)) || deny!()

    installation =
      List.first(
        Ledger.read!(FleetCertificateInstallation,
          host_id: service.host_id,
          generation: active.generation
        )
      ) || deny!()

    unless route.certificate_fingerprint == active.fingerprint and
             DateTime.compare(active.expires_at, now) == :gt and
             installation.service_id == service.id and
             installation.service_generation == service.generation and
             installation.fingerprint == active.fingerprint,
           do: deny!()

    ttl =
      min(
        DateTime.diff(route.expires_at, now, :millisecond),
        DateTime.diff(route.certificate_expires_at, now, :millisecond)
      )

    unless ttl > 0, do: deny!()

    Map.take(route, binding ++ [:id, :revision, :certificate_fingerprint])
    |> Map.merge(%{
      label: endpoint.label,
      addresses: service.addresses,
      ssh_host_key: service.ssh_host_key,
      ttl: min(ttl, 5000)
    })
  end

  defp shared!(resource, filter) do
    resource
    |> Ash.Query.filter(^filter)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one!(actor: SystemActor.compute()) || deny!()
  end

  defp deny!, do: Ledger.rollback(:unauthorized)
end
