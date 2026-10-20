defmodule Marshall.Ingress.WebStreams do
  @moduledoc "Current execution, web sharing and stored-login checks for web streams."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Accounts.{Login, User}
  alias Marshall.Access.Authorization
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Galileo.{Attachment, Integration, PeerTokens}
  alias Marshall.Ingress.{Endpoint, Error, Execution, Services, Token, WebCredential, WebStream}
  alias Marshall.Teams
  require Ash.Query
  # Revocation reaches open streams by user and VM hints (ADR-0142), so the
  # lease bounds only a lost hint plus the renewal interval.
  @ttl 30_000

  @impl true
  def run(input, options, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn -> perform(options[:operation], input.arguments) end) |> Error.result()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:security;concurrency] ingress-web-fresh-lease
  # Lock service -> host -> VM -> credential -> stream. Ordinary private
  # admission/renewal MUST verify current stored login and Cedar web membership;
  # peer admission instead requires the separately checked integration binding.
  # Every renewal MUST retain exact execution, policy and authority bindings;
  # expired or closed leases MUST NOT revive.
  # An explicit TCP 4444 request MUST be refused by ordinary and peer web
  # authority; persisted endpoints cannot select it (`ingress_endpoint_not_editor_port`).
  defp perform(:open, request) do
    service = Services.authenticate!(request.service_token)
    Services.serialize_open!(service.id)
    open_for!(service, request)
  end

  # @cc [owner:ghuntley,label:security;concurrency] ingress-peer-destination-admission
  # Peer opening MUST consume a valid one-use token and independently require its
  # current integration to authorize the attested source and exact target VM.
  # Only the target's primary web endpoint may be selected. The persisted
  # source/integration binding, not the token, governs every later renewal.
  defp perform(:open_peer, request) do
    service = Services.authenticate!(request.service_token)
    Services.serialize_open!(service.id)

    unless OverallsProtocol.IngressName.valid_label?(request.label) and request.app_port == 0,
      do: deny!()

    endpoint = List.first(Ledger.read!(Endpoint, label: request.label)) || deny!()
    candidate = List.first(Ledger.read!(VirtualMachine, id: endpoint.vm_id)) || deny!()

    binding = %{
      vm_id: candidate.id,
      service_generation: service.generation,
      placement_id: candidate.current_placement_id,
      execution_epoch: candidate.execution_epoch,
      generation: candidate.generation
    }

    {vm, host, now} = Execution.web!(service, binding, :exclusive)
    require_owner!(vm)
    endpoint = current_endpoint!(endpoint.id)

    attestation =
      case PeerTokens.verify(request.peer_token) do
        {:ok, attestation} -> attestation
        _ -> deny!()
      end

    peer_authority!(attestation, vm)

    grant =
      create_stream!(
        service,
        host,
        vm,
        endpoint,
        0,
        binding,
        nil,
        %{
          peer_integration_id: attestation.integration_id,
          peer_source_vm_id: attestation.source_vm_id
        },
        now
      )

    %{
      grant: grant,
      attestation: Map.take(attestation, [:source_vm_id, :name, :expires_at])
    }
  end

  defp perform(:renew_web, request) do
    service =
      Marshall.Ingress.Relays.authority_service!(
        Services.authenticate!(request.service_token),
        request.stream_token,
        :web
      )

    renew_for!(service, request)
  end

  defp perform(:close_web, request) do
    service =
      Marshall.Ingress.Relays.authority_service!(
        Services.authenticate!(request.service_token),
        request.stream_token,
        :web
      )

    candidate = candidate!(request.stream_token)
    bind!(candidate, service)
    stream = Ledger.lock!(WebStream, candidate.id) || deny!()
    if is_nil(stream.closed_at), do: Ledger.update!(stream, :close, %{closed_at: Ledger.now()})
    %{closed: true}
  end

  @doc false
  @spec open_for!(Marshall.Ingress.Service.t(), map()) :: map()
  def open_for!(service, request) do
    Services.serialize_open!(service.id)

    unless OverallsProtocol.IngressName.valid_label?(request.label) and
             (request.app_port == 0 or request.app_port in 3000..9999) and
             request.app_port != 4444,
           do: deny!()

    endpoint = List.first(Ledger.read!(Endpoint, label: request.label)) || deny!()
    candidate = List.first(Ledger.read!(VirtualMachine, id: endpoint.vm_id)) || deny!()

    binding = %{
      vm_id: candidate.id,
      service_generation: service.generation,
      placement_id: candidate.current_placement_id,
      execution_epoch: candidate.execution_epoch,
      generation: candidate.generation
    }

    {vm, host, now} = Execution.web!(service, binding, :exclusive)
    require_owner!(vm)
    endpoint = current_endpoint!(endpoint.id)
    credential = identity!(request[:cookie], service, vm, endpoint, request.app_port)

    create_stream!(service, host, vm, endpoint, request.app_port, binding, credential, %{}, now)
  end

  # @cc [owner:ghuntley,label:security] ingress-web-wake-policy
  # Public wake MUST require the current primary endpoint's public policy.
  # Private wake MUST revalidate its stored login and current web membership;
  # generic web authority MUST never select the dedicated editor port.
  @doc false
  @spec authorize_wake!(Marshall.Ingress.Service.t(), map(), VirtualMachine.t(), Endpoint.t()) ::
          Marshall.Accounts.User.t() | nil
  def authorize_wake!(service, request, vm, endpoint) do
    unless OverallsProtocol.ProfilePolicy.allows?(vm.profile, :web) and
             (request.app_port == 0 or request.app_port in 3000..9999) and
             request.app_port != 4444,
           do: deny!()

    require_owner!(vm)
    credential = identity!(request[:cookie], service, vm, endpoint, request.app_port)

    if credential,
      do: Marshall.Accounts.Security.bind(%User{id: credential.user_id}, credential.login_jti)
  end

  @doc false
  @spec renew_for!(Marshall.Ingress.Service.t(), map()) :: map()
  def renew_for!(service, request) do
    candidate = candidate!(request.stream_token)
    bind!(candidate, service)
    # A reconnecting provisioner is inconclusive, not a revocation (ADR-0192).
    {vm, host, _} = Execution.web!(service, candidate, :exclusive, :renew)
    require_owner!(vm)
    endpoint = List.first(Ledger.read!(Endpoint, vm_id: vm.id)) || deny!()

    unless endpoint.label == candidate.label and
             endpoint.policy_revision == candidate.policy_revision and
             port(endpoint, candidate.app_port) == candidate.port,
           do: deny!()

    credential = renewal_authority!(candidate, service, vm, endpoint)

    stream = Ledger.lock!(WebStream, candidate.id) || deny!()

    unless is_nil(stream.closed_at) and DateTime.compare(stream.expires_at, Ledger.now()) == :gt,
      do: deny!()

    expires_at = deadline!(vm, credential, Ledger.now())
    # Conclusive checks are done; a reconnecting provisioner is inconclusive.
    Execution.renewable!(host, Ledger.now())

    stream
    |> Ledger.update!(:renew, %{expires_at: expires_at})
    |> view(credential)
  end

  defp identity!(nil, service, vm, endpoint, app_port) do
    _ = {service, vm}
    unless public?(endpoint, app_port), do: Ledger.rollback(:authentication_required)
    nil
  end

  defp identity!(cookie, service, vm, endpoint, app_port) do
    hash = digest!(cookie, :web_cookie)

    candidate =
      List.first(Ledger.read!(WebCredential, token_hash: hash)) ||
        Ledger.rollback(:authentication_required)

    credential!(candidate.id, service, vm, endpoint, app_port)
  end

  defp credential!(id, service, vm, endpoint, app_port) do
    credential = Ledger.lock!(WebCredential, id) || Ledger.rollback(:authentication_required)

    Marshall.Ingress.Relays.credential_issuer!(credential, service, vm)

    unless credential.vm_id == vm.id and credential.label == endpoint.label and
             credential.app_port == app_port and
             is_nil(credential.revoked_at) and
             DateTime.compare(credential.expires_at, Ledger.now()) == :gt,
           do: Ledger.rollback(:authentication_required)

    user =
      User
      |> Ash.Query.for_read(:internal_lookup)
      |> Ash.Query.filter(id == ^credential.user_id)
      |> Ash.read_one!(actor: SystemActor.compute()) || deny!()

    case Login.present(credential.login_jti, user.id) do
      {:ok, _} -> :ok
      _ -> Ledger.rollback(:authentication_required)
    end

    Authorization.require!(vm, Marshall.Accounts.Security.bind(user, credential.login_jti), "web")
    credential
  end

  defp deadline!(_vm, nil, now), do: DateTime.add(now, @ttl, :millisecond)

  defp deadline!(vm, credential, now) do
    user = Marshall.Accounts.Security.bind(%User{id: credential.user_id}, credential.login_jti)
    maximum = DateTime.add(now, @ttl, :millisecond)
    Authorization.deadline!(vm, user, "web", maximum)
  end

  defp require_owner!(vm) do
    unless match?(
             %User{deleted_at: nil, active: true},
             Marshall.Accounts.Security.current(vm.owner_id)
           ),
           do: deny!()
  end

  defp current_endpoint!(id), do: List.first(Ledger.read!(Endpoint, id: id)) || deny!()
  defp public?(endpoint, app_port), do: app_port == 0 and endpoint.visibility == :public
  defp port(endpoint, 0), do: endpoint.primary_port
  defp port(_, app_port), do: app_port

  defp candidate!(token) do
    hash = digest!(token, :web_stream)
    List.first(Ledger.read!(WebStream, token_hash: hash)) || deny!()
  end

  defp digest!(token, purpose) do
    case Token.digest(token, purpose) do
      {:ok, hash} -> hash
      _ -> deny!()
    end
  end

  defp bind!(stream, service) do
    unless stream.service_id == service.id and stream.service_generation == service.generation and
             stream.host_id == service.host_id,
           do: deny!()
  end

  defp renewal_authority!(stream, service, vm, endpoint) do
    cond do
      stream.credential_id ->
        credential!(stream.credential_id, service, vm, endpoint, stream.app_port)

      stream.peer_integration_id && stream.peer_source_vm_id ->
        peer_authority!(
          %{
            integration_id: stream.peer_integration_id,
            source_vm_id: stream.peer_source_vm_id,
            name: nil
          },
          vm
        )

        nil

      public?(endpoint, stream.app_port) ->
        nil

      true ->
        deny!()
    end
  end

  defp peer_authority!(attestation, target) do
    integration =
      List.first(Ledger.read!(Integration, id: attestation.integration_id)) || deny!()

    source = List.first(Ledger.read!(VirtualMachine, id: attestation.source_vm_id)) || deny!()

    source_attached =
      Attachment
      |> Ash.Query.filter(integration_id == ^integration.id and vm_id == ^source.id)
      |> Ash.exists?(actor: SystemActor.compute())

    source_member =
      is_binary(integration.team_id) and Teams.member?(integration.team_id, source.owner_id)

    source_authorized =
      (is_binary(integration.owner_id) and integration.owner_id == source.owner_id) or
        source_member or source_attached

    target_owned =
      (is_binary(integration.owner_id) and integration.owner_id == target.owner_id) or
        (is_binary(integration.team_id) and Teams.member?(integration.team_id, target.owner_id))

    unless integration.peer and integration.peer_vm_id == target.id and
             (is_nil(attestation.name) or integration.name == attestation.name) and
             source_authorized and target_owned and
             match?(
               %User{deleted_at: nil, active: true},
               Marshall.Accounts.Security.current(source.owner_id)
             ) and
             OverallsProtocol.ProfilePolicy.allows?(source.profile, :egress) and
             source.desired_state == :running and source.observed_state == :running and
             Marshall.Compute.RelocationReadinessState.terminal_allowed?(source),
           do: deny!()

    :ok
  end

  defp create_stream!(service, host, vm, endpoint, app_port, binding, credential, peer, now) do
    query =
      WebStream
      |> Ash.Query.filter(service_id == ^service.id and is_nil(closed_at) and expires_at > ^now)

    if Ash.count!(query, actor: SystemActor.compute()) >= 1024, do: Ledger.rollback(:capacity)
    {ticket, hash} = Token.issue(:web_stream)

    stream =
      Ledger.create!(
        WebStream,
        :record,
        binding
        |> Map.merge(peer)
        |> Map.merge(%{
          token_hash: hash,
          service_id: service.id,
          host_id: host.id,
          label: endpoint.label,
          app_port: app_port,
          port: port(endpoint, app_port),
          policy_revision: endpoint.policy_revision,
          credential_id: credential && credential.id,
          expires_at: deadline!(vm, credential, now)
        })
      )

    Map.put(view(stream, credential), :ticket, ticket)
  end

  defp view(stream, credential) do
    binding =
      Map.take(stream, [
        :vm_id,
        :host_id,
        :placement_id,
        :execution_epoch,
        :generation,
        :label,
        :port
      ])
      |> Map.merge(%{session_id: stream.id, service: :web})

    %{
      binding: binding,
      ttl: max(0, min(@ttl, DateTime.diff(stream.expires_at, Ledger.now(), :millisecond))),
      user_id: credential && credential.user_id
    }
  end

  defp deny!, do: Ledger.rollback(:unauthorized)
end
