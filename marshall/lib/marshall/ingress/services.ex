defmodule Marshall.Ingress.Services do
  @moduledoc "Serialized service enrollment, rotation and current credential verification."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger}
  alias Marshall.Ingress.{Error, Service, Token}
  require Ash.Query
  require Marshall.Events

  @impl true
  def run(input, options, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn -> perform(options[:operation], input.arguments) end)
    |> finish()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  defp finish({:ok, {value, event}}) do
    unless Marshall.Repo.in_transaction?(), do: emit_event(event)
    {:ok, value}
  end

  defp finish({:error, reason}) when is_atom(reason),
    do: {:error, Error.exception(reason: reason)}

  defp finish(result), do: result

  # @cc [owner:ghuntley,label:security;recovery] ingress-bootstrap-no-resurrection
  # Ensure MUST create an absent identity or preserve an enabled identity with
  # exactly the same role, host, credential and normalized addresses. It MUST NOT
  # rotate authority, clear host keys, or revive disabled identities. Conflicts
  # MUST leave both the identity and its audit history unchanged.
  defp perform(:ensure, request) do
    token_hash = digest!(request.token)
    host_id = Map.get(request, :host_id)
    addresses = addresses!(request.role, request.addresses)
    relay = relay!(request)

    unless (request.role == :dns and is_nil(host_id)) or
             (request.role == :gateway and is_binary(host_id) and
                Ledger.read!(Host, id: host_id) != []),
           do: Ledger.rollback(:invalid_binding)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["audi-service:" <> request.name],
      log: false
    )

    case Ledger.read!(Service, name: request.name) do
      [] ->
        Service
        |> Ledger.create!(:record, %{
          name: request.name,
          role: request.role,
          host_id: host_id,
          token_hash: token_hash,
          addresses: addresses,
          relay_address: relay.address,
          relay_port: relay.port
        })
        |> configured()

      [existing] ->
        service = Ledger.lock!(Service, existing.id)

        if service.role != request.role or service.host_id != host_id,
          do: Ledger.rollback(:binding_conflict)

        unless service.enabled and service.token_hash == token_hash and
                 service.addresses == addresses and service.relay_address == relay.address and
                 service.relay_port == relay.port,
               do: Ledger.rollback(:unauthorized)

        {view(service), nil}
    end
  end

  defp perform(:configure, request) do
    token_hash = digest!(request.token)
    host_id = Map.get(request, :host_id)
    addresses = addresses!(request.role, request.addresses)
    relay = relay!(request)

    unless (request.role == :dns and is_nil(host_id)) or
             (request.role == :gateway and is_binary(host_id) and
                Ledger.read!(Host, id: host_id) != []),
           do: Ledger.rollback(:invalid_binding)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["audi-service:" <> request.name],
      log: false
    )

    case Ledger.read!(Service, name: request.name) do
      [] ->
        Service
        |> Ledger.create!(:record, %{
          name: request.name,
          role: request.role,
          host_id: host_id,
          token_hash: token_hash,
          addresses: addresses,
          relay_address: relay.address,
          relay_port: relay.port
        })
        |> configured()

      [existing] ->
        service = Ledger.lock!(Service, existing.id)

        if service.role != request.role or service.host_id != host_id,
          do: Ledger.rollback(:binding_conflict)

        cond do
          service.enabled and service.token_hash == token_hash and service.addresses == addresses and
            service.relay_address == relay.address and service.relay_port == relay.port ->
            {view(service), {:service_configured, service.id, service.host_id}}

          not service.enabled and service.token_hash == token_hash ->
            Ledger.rollback(:revoked_credential)

          true ->
            service
            |> Ledger.update!(:rotate, %{
              token_hash: token_hash,
              generation: service.generation + 1,
              enabled: true,
              ssh_host_key: nil,
              addresses: addresses,
              relay_address: relay.address,
              relay_port: relay.port
            })
            |> configured()
        end
    end
  end

  defp perform(:disable, %{id: id}) do
    case Ledger.lock!(Service, id) do
      nil ->
        Ledger.rollback(:service_not_found)

      %{enabled: false} = service ->
        {view(service), nil}

      service ->
        service
        |> Ledger.update!(:rotate, %{
          enabled: false,
          generation: service.generation + 1,
          ssh_host_key: nil
        })
        |> then(&{view(&1), {:service_disabled, &1.id, &1.host_id}})
    end
  end

  defp perform(:identity, %{token: token}), do: token |> authenticate!() |> then(&{view(&1), nil})

  # @cc [owner:ghuntley,label:security;concurrency] ingress-host-key-generation
  # Publication MUST exclusively lock the current credential's gateway identity.
  # Only a canonical Ed25519 public key may be registered, immutably within one
  # credential generation. Rotation/revocation MUST atomically clear the key.
  # Publication establishes neither placement readiness nor user authority.
  defp perform(:publish_host_key, %{token: token, public_key: key}) do
    service = authenticate!(token, :exclusive)
    unless service.role == :gateway, do: Ledger.rollback(:unauthorized)

    canonical =
      case OverallsProtocol.SSHKey.parse(key) do
        {:ok, %{algorithm: "ssh-ed25519", public_key: ^key}} -> key
        _ -> Ledger.rollback(:invalid_request)
      end

    service =
      case service.ssh_host_key do
        nil -> Ledger.update!(service, :record_host_key, %{ssh_host_key: canonical})
        ^canonical -> service
        _ -> Ledger.rollback(:host_key_conflict)
      end

    {%{
       service_id: service.id,
       host_id: service.host_id,
       generation: service.generation,
       public_key: service.ssh_host_key
     }, {:host_key_published, service.id, service.host_id}}
  end

  # @cc [owner:ghuntley,label:security] ingress-relay-endpoint-enrollment
  # Relay endpoints MUST come only from operator enrollment. DNS credentials
  # MUST have none; gateway endpoints MUST use the authenticated fleet network.
  @spec relay!(map()) :: %{address: String.t() | nil, port: pos_integer()}
  defp relay!(request) do
    address = Map.get(request, :relay_address)
    port = Map.get(request, :relay_port, 9445)

    unless (is_nil(address) or
              (request.role == :gateway and OverallsProtocol.IngressRelay.fleet_address?(address))) and
             is_integer(port) and port in 1..65_535,
           do: Ledger.rollback(:invalid_binding)

    %{address: address, port: port}
  end

  # @cc [owner:ghuntley,label:concurrency;capacity] ingress-admission-capacity-lock
  # Admission counts MUST serialize per destination gateway before host/VM locks.
  # Shared service locks permit reciprocal one-hop admission without lock upgrades.
  @doc false
  @spec serialize_open!(String.t()) :: :ok
  def serialize_open!(id) do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["audi-stream-open:" <> id],
      log: false
    )

    :ok
  end

  # @cc [owner:ghuntley,label:security;concurrency] ingress-service-current-credential
  # Callers MUST retain their transaction through dependent admission. A shared
  # row lock excludes rotation/revocation during admission. Service identity
  # establishes neither an end-user actor nor authority to connect to a guest.
  @spec authenticate!(binary(), :shared | :exclusive) :: Service.t()
  def authenticate!(token, mode \\ :shared) do
    unless Marshall.Repo.in_transaction?(),
      do: raise("Audi authentication requires a transaction")

    hash =
      case Token.digest(token) do
        {:ok, hash} -> hash
        :error -> reject!(:invalid_credential)
      end

    query =
      Service
      |> Ash.Query.filter(token_hash == ^hash and enabled == true)
      |> Ash.Query.lock(if(mode == :exclusive, do: "FOR UPDATE", else: "FOR SHARE"))

    Ash.read_one!(query, actor: SystemActor.compute()) || reject!(:unknown_service)
  end

  defp reject!(reason) do
    Marshall.Events.emit("ingress.service_auth_rejected", reason: reason)
    Ledger.rollback(:unauthorized)
  end

  defp digest!(token) do
    case Token.digest(token) do
      {:ok, hash} -> hash
      :error -> Ledger.rollback(:unauthorized)
    end
  end

  # @cc [owner:ghuntley,label:security;concurrency] ingress-gateway-address-generation
  # Only operator enrollment may configure at most eight canonical IP literals;
  # DNS service identities MUST have none. Address changes MUST advance the
  # service generation and clear its SSH host key under the service row lock.
  # Ordering alone MUST NOT rotate identity. Addresses do not prove readiness.
  defp addresses!(role, values) do
    unless is_list(values) and length(values) <= 8 and
             (role == :gateway or values == []),
           do: Ledger.rollback(:invalid_binding)

    Enum.each(values, fn value ->
      unless is_binary(value) and String.valid?(value), do: Ledger.rollback(:invalid_binding)

      case :inet.parse_ipv4strict_address(String.to_charlist(value)) do
        {:ok, ip} ->
          unless List.to_string(:inet.ntoa(ip)) == value,
            do: Ledger.rollback(:invalid_binding)

        _ ->
          Ledger.rollback(:invalid_binding)
      end
    end)

    if Enum.uniq(values) != values, do: Ledger.rollback(:invalid_binding)
    Enum.sort(values)
  end

  defp view(service), do: Map.take(service, [:id, :name, :role, :host_id, :generation, :enabled])

  defp configured(service),
    do: {view(service), {:service_configured, service.id, service.host_id}}

  defp emit_event({:service_configured, service_id, nil}),
    do: Marshall.Events.emit("ingress.service_configured", service_id: service_id)

  defp emit_event({:service_configured, service_id, host_id}),
    do:
      Marshall.Events.emit("ingress.service_configured", service_id: service_id, host_id: host_id)

  defp emit_event({:service_disabled, service_id, nil}),
    do: Marshall.Events.emit("ingress.service_disabled", service_id: service_id)

  defp emit_event({:service_disabled, service_id, host_id}),
    do: Marshall.Events.emit("ingress.service_disabled", service_id: service_id, host_id: host_id)

  defp emit_event({:host_key_published, service_id, host_id}),
    do:
      Marshall.Events.emit("ingress.host_key_published", service_id: service_id, host_id: host_id)

  defp emit_event(nil), do: :ok
end
