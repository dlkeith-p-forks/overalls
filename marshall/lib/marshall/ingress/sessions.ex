defmodule Marshall.Ingress.Sessions do
  @moduledoc "Fresh key, membership and physical placement checks for every Audi SSH grant."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Access.Authorization
  alias Marshall.Compute.{Host, Ledger, Operation, VirtualMachine}
  alias Marshall.Ingress.{Endpoint, Error, Execution, Services, Session, Token}
  alias Marshall.SSH.Key
  require Ash.Query
  require Marshall.Events
  # Revocation reaches open sessions by user and VM hints (ADR-0142).
  @ttl 30_000

  @impl true
  def run(input, options, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn -> perform(options[:operation], input.arguments) end) |> finish()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  defp finish({:ok, {value, event}}) do
    unless Marshall.Repo.in_transaction?(), do: emit_event(event)
    {:ok, value}
  end

  defp finish({:error, reason}) when is_atom(reason),
    do: {:error, Error.exception(reason: reason)}

  defp finish(result), do: result

  # @cc [owner:ghuntley,label:security] ingress-key-status-proof-only
  # Only a credentialed gateway attesting completed signature proof MAY query
  # recognition. This action MUST NOT create sessions or expose account data.
  defp perform(:key_status, request) do
    gateway!(request.service_token)

    case OverallsProtocol.SSHKey.parse(request.public_key) do
      {:ok, parsed} ->
        status = if Marshall.SSH.KeyRegistry.find(parsed), do: :recognized, else: :unknown
        {%{status: status}, nil}

      _ ->
        deny!()
    end
  end

  # @cc [owner:ghuntley,label:security;concurrency] ingress-ssh-fresh-admission
  # Only a credentialed gateway attesting completed SSH signature proof may open
  # a session. Lock service, key, host, VM, then session in that order. Admission
  # MUST require current Cedar write membership, live physical execution on this
  # host, and completed relocation readiness. No public endpoint grants SSH.
  defp perform(:open, request) do
    service = gateway!(request.service_token)
    open_for!(service, request)
  end

  # @cc [owner:ghuntley,label:security] ingress-ssh-renewal-no-resurrection
  # Renewal MUST revalidate the exact unarchived key identity, gateway generation,
  # current membership and immutable execution binding. Expired/closed sessions
  # MUST never revive. The five-second client deadline begins before its request.
  # A provisioner that is only reconnecting (ingress-renewal-host-reconnecting)
  # MUST be decided last, after every conclusive check, as
  # :temporarily_unavailable, leaving the lease unchanged (ADR-0187, ADR-0192).
  defp perform(:renew_ssh, request) do
    service =
      Marshall.Ingress.Relays.authority_service!(
        gateway!(request.service_token),
        request.session_token,
        :ssh
      )

    renew_for!(service, request)
  end

  defp perform(:close_ssh, request) do
    service =
      Marshall.Ingress.Relays.authority_service!(
        gateway!(request.service_token),
        request.session_token,
        :ssh
      )

    candidate = by_token!(request.session_token)
    session = Ledger.lock!(Session, candidate.id) || deny!()
    bind_service!(session, service)
    if is_nil(session.closed_at), do: Ledger.update!(session, :close, %{closed_at: Ledger.now()})
    {%{closed: true}, {:ssh_session_closed, session.id}}
  end

  @doc false
  @spec open_for!(Marshall.Ingress.Service.t(), map()) :: {map(), tuple()}
  def open_for!(service, request) do
    Services.serialize_open!(service.id)
    unless OverallsProtocol.IngressName.valid_label?(request.label), do: deny!()

    parsed =
      case OverallsProtocol.SSHKey.parse(request.public_key) do
        {:ok, key} -> key
        _ -> deny!()
      end

    key = Marshall.SSH.KeyRegistry.find(parsed, :share) || deny!()
    user = user!(key)
    host = host!(service.host_id)
    endpoint = List.first(Ledger.read!(Endpoint, label: request.label)) || deny!()
    vm = Authorization.live_vm!(endpoint.vm_id, user, "write")
    ready!(vm, host)
    now = Ledger.now()

    active =
      Session
      |> Ash.Query.filter(service_id == ^service.id and is_nil(closed_at) and expires_at > ^now)

    if Ash.count!(active, actor: SystemActor.compute()) >= 128,
      do: Ledger.rollback(:session_limit)

    {token, hash} = Token.issue(:session)

    session =
      Ledger.create!(Session, :record, %{
        token_hash: hash,
        service_id: service.id,
        service_generation: service.generation,
        key_id: key.id,
        vm_id: vm.id,
        host_id: host.id,
        placement_id: vm.current_placement_id,
        execution_epoch: vm.execution_epoch,
        generation: vm.generation,
        label: endpoint.label,
        expires_at: DateTime.add(now, @ttl, :millisecond)
      })

    {Map.put(view(session), :ticket, token), {:ssh_session_opened, vm.id, host.id, session.id}}
  end

  # @cc [owner:ghuntley,label:security] ingress-ssh-wake-proof
  # Waking MUST require the same proved registered key and current VM write
  # permission as stream admission. This check MUST NOT create a stream.
  @doc false
  @spec authorize_wake!(map(), VirtualMachine.t()) :: Marshall.Accounts.User.t()
  def authorize_wake!(request, vm) do
    parsed =
      case OverallsProtocol.SSHKey.parse(request.public_key) do
        {:ok, key} -> key
        _ -> deny!()
      end

    key = Marshall.SSH.KeyRegistry.find(parsed, :share) || deny!()
    user = user!(key)
    Authorization.require!(vm, user, "write")
    user
  end

  @doc false
  @spec renew_for!(Marshall.Ingress.Service.t(), map()) :: {map(), nil}
  def renew_for!(service, request) do
    candidate = by_token!(request.session_token)
    bind_service!(candidate, service)
    key = shared!(Key, id: candidate.key_id)
    user = user!(key)
    host = host!(service.host_id, :renew)
    vm = Authorization.live_vm!(candidate.vm_id, user, "write")
    session = Ledger.lock!(Session, candidate.id) || deny!()
    bind_service!(session, service)
    live!(session)
    ready!(vm, host, :renew)

    unless session.placement_id == vm.current_placement_id and
             session.execution_epoch == vm.execution_epoch and session.generation == vm.generation,
           do: deny!()

    Execution.renewable!(host, Ledger.now())

    session
    |> Ledger.update!(:renew, %{expires_at: DateTime.add(Ledger.now(), @ttl, :millisecond)})
    |> then(&{view(&1), nil})
  end

  defp gateway!(token) do
    service = Services.authenticate!(token)
    if service.role != :gateway, do: deny!()
    service
  end

  # Admission requires a live, reported host session. Renewal also accepts a
  # reconnecting one here; Execution.renewable!/2 then decides it last.
  defp host!(id, purpose \\ :admit) do
    host = shared!(Host, id: id)

    unless host.enabled and host.maintenance_mode != :retired and
             (live?(host) or (purpose == :renew and reconnecting?(host))),
           do: deny!()

    host
  end

  defp live?(host),
    do:
      is_binary(host.connection_session_id) and
        Marshall.Compute.HostLiveness.authority?(
          host.connection_session_id,
          host.reported_at,
          Ledger.now()
        )

  defp reconnecting?(host),
    do: not is_binary(host.connection_session_id) or is_nil(host.reported_at)

  defp ready!(vm, host, purpose \\ :admit) do
    unless (live?(host) or (purpose == :renew and reconnecting?(host))) and
             vm.host_id == host.id and
             vm.desired_state == :running and
             vm.observed_state == :running and
             Marshall.Compute.RelocationReadinessState.terminal_allowed?(vm) and
             Enum.any?(
               Ledger.read!(Operation,
                 vm_id: vm.id,
                 placement_id: vm.current_placement_id,
                 execution_epoch: vm.execution_epoch,
                 generation: vm.generation
               ),
               &(&1.status == :completed and &1.kind in [:provision, :start, :resume])
             ),
           do: deny!()
  end

  defp shared!(resource, filter) do
    resource
    |> Ash.Query.filter(^filter)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one!(actor: SystemActor.compute()) || deny!()
  end

  defp user!(key) do
    Marshall.Accounts.User
    |> Ash.Query.for_read(:internal_lookup)
    |> Ash.Query.filter(id == ^key.user_id)
    |> Ash.read_one!(actor: SystemActor.compute()) || deny!()
  end

  defp by_token!(token) do
    hash =
      case Token.digest(token, :session) do
        {:ok, hash} -> hash
        _ -> deny!()
      end

    List.first(Ledger.read!(Session, token_hash: hash)) || deny!()
  end

  defp bind_service!(session, service) do
    unless session.service_id == service.id and session.service_generation == service.generation and
             session.host_id == service.host_id,
           do: deny!()
  end

  defp live!(session) do
    if session.closed_at != nil or DateTime.compare(session.expires_at, Ledger.now()) != :gt,
      do: deny!()
  end

  defp view(session) do
    binding =
      Map.take(session, [:vm_id, :host_id, :placement_id, :execution_epoch, :generation, :label])
      |> Map.merge(%{session_id: session.id, service: :ssh, port: 22})

    %{binding: binding, ttl: @ttl, user_id: key_user(session.key_id)}
  end

  # The session's user, so the gateway renews it at once on that user's hints.
  @spec key_user(String.t()) :: String.t() | nil
  defp key_user(key_id) do
    case Ledger.read!(Key, id: key_id) do
      [%{user_id: user}] -> user
      _ -> nil
    end
  end

  defp deny!, do: Ledger.rollback(:unauthorized)

  defp emit_event({:ssh_session_opened, vm_id, host_id, session_id}),
    do:
      Marshall.Events.emit("ingress.ssh_session_opened",
        vm_id: vm_id,
        host_id: host_id,
        session_id: session_id
      )

  defp emit_event({:ssh_session_closed, session_id}),
    do: Marshall.Events.emit("ingress.ssh_session_closed", session_id: session_id)

  defp emit_event(nil), do: :ok
end
