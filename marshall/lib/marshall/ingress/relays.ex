defmodule Marshall.Ingress.Relays do
  @moduledoc "Current gateway and exact-stream authority for one-hop fleet handoff."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, HostLiveness, Ledger, VirtualMachine}
  alias Marshall.Ingress.{Error, Relay, Service, Services}
  alias OverallsProtocol.IngressRelay
  require Ash.Query
  require Marshall.Events

  @impl true
  def run(input, options, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn -> connection!(options[:operation], input.arguments) end)
    |> Error.result()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:security] ingress-browser-credential-location
  # A relocated endpoint cookie MAY be used at its current authoritative gateway
  # or an authenticated one-hop origin. Its issuing gateway generation MUST still
  # be enabled; the exact VM/app/account, stored login and policy remain mandatory.
  @spec credential_issuer!(struct(), Service.t(), VirtualMachine.t()) :: :ok
  def credential_issuer!(credential, service, vm) do
    issuer = shared!(Service, credential.service_id)

    unless issuer.enabled and issuer.generation == credential.service_generation and
             issuer.role == :gateway and service.enabled and service.role == :gateway and
             (service.id == issuer.id or service.host_id == vm.host_id or
                (IngressRelay.fleet_address?(service.relay_address) and
                   IngressRelay.fleet_address?(issuer.relay_address))),
           do: Ledger.rollback(:authentication_required)

    :ok
  end

  @doc false
  @spec serialize_origin!(String.t()) :: :ok
  def serialize_origin!(id) do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["audi-relay-origin:" <> id],
      log: false
    )

    :ok
  end

  # @cc [owner:ghuntley,label:security;concurrency] ingress-relay-origin-host-authority
  # Wake demand and relay admission, consume and renewal MUST require an enabled,
  # nonretired origin with current host authority. Both endpoint hosts MUST be
  # locked in UUID order before any VM or relay row. Enabled evacuating hosts
  # retain authority; destination execution keeps its independent admission and
  # inconclusive reconnect checks.
  @doc false
  @spec authorize_origin!(Service.t(), Service.t()) :: :ok
  def authorize_origin!(source, destination) do
    hosts =
      [source.host_id, destination.host_id]
      |> Enum.uniq()
      |> Enum.sort()
      |> Map.new(fn id -> {id, shared!(Host, id)} end)

    origin = Map.fetch!(hosts, source.host_id)

    unless origin.enabled and origin.maintenance_mode != :retired and
             HostLiveness.authority?(
               origin.connection_session_id,
               origin.reported_at,
               Ledger.now()
             ),
           do: deny!()

    :ok
  end

  @spec issue!(Service.t(), Service.t(), :ssh | :web | :editor, map()) :: map()
  def issue!(source, destination, purpose, grant) do
    unless source.host_id != destination.host_id and
             IngressRelay.fleet_address?(source.relay_address) and
             IngressRelay.fleet_address?(destination.relay_address),
           do: deny!()

    now = Ledger.now()
    # A bounded sweep on admission prevents expired capabilities accumulating.
    Relay
    |> Ash.Query.filter(expires_at <= ^now)
    |> Ash.Query.sort(expires_at: :asc)
    |> Ash.Query.limit(128)
    |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.each(&Ash.destroy!(&1, action: :purge, actor: SystemActor.compute()))

    active = Relay |> Ash.Query.filter(origin_service_id == ^source.id and expires_at > ^now)
    if Ash.count!(active, actor: SystemActor.compute()) >= 128, do: Ledger.rollback(:capacity)
    capability = "audi_relay_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    relay =
      Ledger.create!(Relay, :record, %{
        token_hash: hash(capability),
        stream_token_hash: hash(grant.ticket),
        origin_service_id: source.id,
        origin_service_generation: source.generation,
        destination_service_id: destination.id,
        destination_service_generation: destination.generation,
        origin_host_id: source.host_id,
        destination_host_id: destination.host_id,
        origin_address: source.relay_address,
        destination_address: destination.relay_address,
        destination_port: destination.relay_port,
        purpose: purpose,
        binding: JSON.decode!(JSON.encode!(grant.binding)),
        consume_by: DateTime.add(now, 10_000, :millisecond),
        expires_at: DateTime.add(now, grant.ttl, :millisecond)
      })

    Ledger.after_commit(fn ->
      Marshall.Events.emit("ingress.relay_issued",
        relay_id: relay.id,
        origin_host_id: relay.origin_host_id,
        destination_host_id: relay.destination_host_id
      )
    end)

    %{
      origin_host_id: source.host_id,
      destination_host_id: destination.host_id,
      address: destination.relay_address,
      port: destination.relay_port,
      capability: capability
    }
  end

  # @cc [owner:ghuntley,label:security] ingress-relay-origin-renewal
  # An origin may renew/close only the exact inner ticket it handed off. Both
  # gateway generations, origin host authority and the handoff deadline MUST
  # remain current. Ordinary local grants MUST retain their original checks.
  @spec authority_service!(Service.t(), String.t(), :ssh | :web | :editor) :: Service.t()
  def authority_service!(source, ticket, purpose) do
    case Ledger.read!(Relay,
           origin_service_id: source.id,
           stream_token_hash: hash(ticket),
           purpose: purpose
         ) do
      [] ->
        source

      [candidate] ->
        destination = current_services!(candidate, source)
        relay = Ledger.lock!(Relay, candidate.id) || deny!()
        live!(relay)

        Ledger.update!(relay, :renew, %{
          expires_at: DateTime.add(Ledger.now(), 30_000, :millisecond)
        })

        destination
    end
  end

  @spec destination!(Service.t(), String.t()) :: Service.t()
  def destination!(source, host_id) do
    if source.host_id == host_id do
      source
    else
      candidate =
        Service
        |> Ash.Query.filter(
          host_id == ^host_id and role == :gateway and enabled == true and
            not is_nil(relay_address)
        )
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(actor: SystemActor.compute()) || deny!()

      destination = shared!(Service, candidate.id)

      unless IngressRelay.fleet_address?(source.relay_address) and
               IngressRelay.fleet_address?(destination.relay_address),
             do: deny!()

      destination
    end
  end

  @spec connection!(atom(), map()) :: map()
  defp connection!(operation, request) do
    destination = Services.authenticate!(request.service_token)

    unless IngressRelay.capability?(request.capability) and
             IngressRelay.fleet_address?(request.peer_address),
           do: deny!()

    candidate = List.first(Ledger.read!(Relay, token_hash: hash(request.capability))) || deny!()
    source = shared!(Service, candidate.origin_service_id)
    current = current_services!(candidate, source)

    unless current.id == destination.id and current.generation == destination.generation,
      do: deny!()

    relay = Ledger.lock!(Relay, candidate.id) || deny!()

    unless relay.stream_token_hash == hash(request.ticket) and relay.purpose == request.purpose and
             relay.origin_address == request.peer_address,
           do: deny!()

    live!(relay)

    case operation do
      :consume_connection ->
        unless is_nil(relay.consumed_at) and
                 DateTime.compare(Ledger.now(), relay.consume_by) == :lt,
               do: deny!()

        Ledger.update!(relay, :consume, %{consumed_at: Ledger.now()})

        Ledger.after_commit(fn ->
          Marshall.Events.emit("ingress.relay_consumed",
            relay_id: relay.id,
            origin_host_id: relay.origin_host_id,
            destination_host_id: relay.destination_host_id
          )
        end)

      :renew_connection ->
        unless not is_nil(relay.consumed_at), do: deny!()
    end

    grant = renew_inner!(destination, relay.purpose, request.ticket)
    unless JSON.decode!(JSON.encode!(grant.binding)) == relay.binding, do: deny!()

    Ledger.update!(relay, :renew, %{
      expires_at: DateTime.add(Ledger.now(), grant.ttl, :millisecond)
    })

    Map.put(grant, :ticket, request.ticket)
  end

  @spec renew_inner!(Service.t(), :ssh | :web | :editor, String.t()) :: map()
  defp renew_inner!(service, :ssh, ticket) do
    {grant, nil} = Marshall.Ingress.Sessions.renew_for!(service, %{session_token: ticket})
    grant
  end

  defp renew_inner!(service, :web, ticket),
    do: Marshall.Ingress.WebStreams.renew_for!(service, %{stream_token: ticket})

  defp renew_inner!(service, :editor, ticket),
    do: Marshall.Editor.Authority.renew_for!(service, %{stream_token: ticket})

  @spec current_services!(Relay.t(), Service.t()) :: Service.t()
  defp current_services!(relay, source) do
    destination = shared!(Service, relay.destination_service_id)
    authorize_origin!(source, destination)

    unless source.enabled and source.id == relay.origin_service_id and
             source.generation == relay.origin_service_generation and
             source.host_id == relay.origin_host_id and
             source.relay_address == relay.origin_address and
             destination.enabled and
             destination.generation == relay.destination_service_generation and
             destination.host_id == relay.destination_host_id and
             destination.relay_address == relay.destination_address and
             destination.relay_port == relay.destination_port,
           do: deny!()

    destination
  end

  @spec live!(Relay.t()) :: :ok
  defp live!(relay) do
    unless DateTime.compare(relay.expires_at, Ledger.now()) == :gt and
             (not is_nil(relay.consumed_at) or
                DateTime.compare(relay.consume_by, Ledger.now()) == :gt),
           do: deny!()

    :ok
  end

  @spec shared!(module(), String.t()) :: struct()
  defp shared!(resource, id),
    do:
      resource
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one!(actor: SystemActor.compute()) || deny!()

  @spec hash(binary()) :: binary()
  defp hash(token), do: :crypto.hash(:sha256, token)
  @spec deny!() :: no_return()
  defp deny!, do: Ledger.rollback(:unauthorized)
end
