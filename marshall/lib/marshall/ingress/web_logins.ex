defmodule Marshall.Ingress.WebLogins do
  @moduledoc "Single-use browser authorization with current login, membership and execution checks."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Accounts.{Login, User}
  alias Marshall.Access.Authorization
  alias Marshall.Compute.{Ledger, VirtualMachine}

  alias Marshall.Ingress.{
    Endpoint,
    Error,
    Execution,
    Service,
    Services,
    Token,
    WebCredential,
    WebLogin
  }

  require Ash.Query
  require Marshall.Events

  @impl true
  def run(input, [operation: :authorize], %{actor: %User{} = user}) do
    Ledger.transaction(fn -> authorize!(input.arguments, user) end) |> finish()
  end

  def run(input, [operation: operation], %{actor: %SystemActor{purpose: :compute}})
      when operation in [:begin, :exchange] do
    Ledger.transaction(fn -> perform(operation, input.arguments) end) |> finish()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  defp finish({:ok, {value, event}}) do
    unless Marshall.Repo.in_transaction?(), do: emit_event(event)
    {:ok, value}
  end

  defp finish({:error, {:web_login_denied, reason}}) do
    unless Marshall.Repo.in_transaction?(),
      do: Marshall.Events.emit("ingress.web_login_denied", reason: reason)

    {:error, Error.exception(reason: :unauthorized)}
  end

  defp finish({:error, reason}) when is_atom(reason),
    do: {:error, Error.exception(reason: reason)}

  defp finish(result), do: result

  # @cc [owner:ghuntley,label:security;concurrency] ingress-browser-state-exchange
  # Begin MUST bind current gateway execution, exact VM/app and a canonical state
  # digest. Approval MUST verify the original live login and current web sharing.
  # Exchange MUST require the same gateway, code and browser state, recheck login
  # and membership, and atomically consume the exchange with credential creation.
  # Expired, consumed or mismatched exchanges MUST NOT issue credentials. Locks
  # MUST follow service -> host -> VM -> exchange; raw proofs never persist.
  defp perform(:begin, request) do
    service = Services.authenticate!(request.service_token, :exclusive)

    unless OverallsProtocol.IngressName.valid_label?(request.label) and
             (request.app_port == 0 or request.app_port in 3000..9999) and
             request.app_port != 4444,
           do: deny!(:invalid_binding)

    state_hash =
      case Base.decode16(request.state_digest, case: :lower) do
        {:ok, hash} when byte_size(hash) == 32 -> hash
        _ -> deny!(:invalid_state)
      end

    endpoint =
      List.first(Ledger.read!(Endpoint, label: request.label)) || deny!(:unknown_endpoint)

    vm = List.first(Ledger.read!(VirtualMachine, id: endpoint.vm_id)) || deny!(:unknown_vm)

    binding = %{
      vm_id: vm.id,
      service_generation: service.generation,
      placement_id: vm.current_placement_id,
      execution_epoch: vm.execution_epoch,
      generation: vm.generation
    }

    {vm, host, now} = Execution.web!(service, binding, :exclusive)

    query =
      WebLogin
      |> Ash.Query.filter(service_id == ^service.id and expires_at > ^now and status != :consumed)

    if Ash.count!(query, actor: SystemActor.compute()) >= 128, do: Ledger.rollback(:capacity)
    {ticket, hash} = Token.issue(:web_login)

    login =
      Ledger.create!(
        WebLogin,
        :record,
        Map.merge(binding, %{
          service_id: service.id,
          host_id: host.id,
          vm_id: vm.id,
          token_hash: hash,
          state_hash: state_hash,
          label: endpoint.label,
          app_port: request.app_port,
          expires_at: DateTime.add(now, 300)
        })
      )

    {%{ticket: ticket, hostname: hostname!(login), expires_at: login.expires_at},
     {:web_login_started}}
  end

  defp perform(:exchange, request) do
    service = Services.authenticate!(request.service_token, :exclusive)
    candidate = candidate!(request.ticket)
    unless candidate.service_id == service.id, do: deny!(:service_mismatch)
    {vm, _, _} = Execution.web!(service, candidate, :exclusive)
    login = Ledger.lock!(WebLogin, candidate.id) || deny!(:unknown_login)
    live!(login, :approved)

    unless login.service_id == service.id and login.service_generation == service.generation,
      do: deny!(:generation_mismatch)

    code =
      case Token.digest(request.code, :web_code) do
        {:ok, digest} -> digest
        _ -> deny!(:invalid_code)
      end

    unless Plug.Crypto.secure_compare(code, login.code_hash), do: deny!(:invalid_code)

    state =
      case Base.url_decode64(request.state, padding: false) do
        {:ok, bytes} when byte_size(bytes) == 32 ->
          unless Base.url_encode64(bytes, padding: false) == request.state,
            do: deny!(:invalid_state)

          :crypto.hash(:sha256, request.state)

        _ ->
          deny!(:invalid_state)
      end

    unless Plug.Crypto.secure_compare(state, login.state_hash), do: deny!(:state_mismatch)

    user =
      User
      |> Ash.Query.for_read(:internal_lookup)
      |> Ash.Query.filter(id == ^login.user_id)
      |> Ash.read_one!(actor: SystemActor.compute()) || deny!(:unknown_user)

    expires =
      case Login.present(login.login_jti, user.id) do
        {:ok, value} -> value
        _ -> deny!(:login_expired)
      end

    Authorization.require!(vm, Marshall.Accounts.Security.bind(user, login.login_jti), "web")
    now = Ledger.now()

    query =
      WebCredential
      |> Ash.Query.filter(service_id == ^service.id and is_nil(revoked_at) and expires_at > ^now)

    if Ash.count!(query, actor: SystemActor.compute()) >= 1024, do: Ledger.rollback(:capacity)
    {cookie, hash} = Token.issue(:web_cookie)

    credential =
      Ledger.create!(WebCredential, :record, %{
        token_hash: hash,
        user_id: user.id,
        login_jti: login.login_jti,
        vm_id: vm.id,
        service_id: service.id,
        service_generation: service.generation,
        label: login.label,
        app_port: login.app_port,
        expires_at: earlier(expires, DateTime.add(now, 43_200))
      })

    Ledger.update!(login, :consume, %{})

    {%{cookie: cookie, hostname: hostname!(login), expires_at: credential.expires_at},
     {:web_login_exchanged, vm.id}}
  end

  defp authorize!(request, user) do
    {jti, expiry} =
      case Login.verify(request.login_token, user) do
        {:ok, jti, expiry} -> {jti, expiry}
        _ -> deny!(:invalid_login_token)
      end

    candidate = candidate!(request.ticket)

    service =
      Service
      |> Ash.Query.filter(id == ^candidate.service_id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one!(actor: SystemActor.compute())

    unless service, do: deny!(:unknown_service)
    {vm, _, _} = Execution.web!(service, candidate, :exclusive)
    Authorization.require!(vm, Marshall.Accounts.Security.bind(user, jti), "web")
    login = Ledger.lock!(WebLogin, candidate.id) || deny!(:unknown_login)
    live!(login, :pending)
    {code, hash} = Token.issue(:web_code)

    login =
      Ledger.update!(login, :approve, %{
        code_hash: hash,
        user_id: user.id,
        login_jti: jti,
        expires_at: earlier(login.expires_at, earlier(expiry, DateTime.add(Ledger.now(), 60)))
      })

    {%{code: code, ticket: request.ticket, hostname: hostname!(login)},
     {:web_login_approved, user.id, vm.id}}
  end

  defp candidate!(ticket) do
    hash =
      case Token.digest(ticket, :web_login) do
        {:ok, hash} -> hash
        _ -> deny!(:unknown_login)
      end

    List.first(Ledger.read!(WebLogin, token_hash: hash)) || deny!(:unknown_login)
  end

  defp live!(login, status) do
    unless login.status == status and DateTime.compare(login.expires_at, Ledger.now()) == :gt,
      do: deny!(if(status == :pending, do: :login_not_pending, else: :login_not_approved))
  end

  defp hostname!(login) do
    zone = Application.fetch_env!(:marshall, :ingress_zone)

    unless is_binary(zone) and byte_size(zone) in 1..189 and
             Enum.all?(
               String.split(zone, "."),
               &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1)
             ),
           do: deny!(:invalid_zone)

    label =
      if login.app_port == 0,
        do: login.label,
        else: OverallsProtocol.IngressName.alternate_label(login.label, login.app_port)

    hostname = label <> "." <> zone
    unless byte_size(hostname) <= 253, do: deny!(:invalid_hostname)
    hostname
  end

  defp earlier(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp deny!(reason), do: Marshall.Repo.rollback({:web_login_denied, reason})

  defp emit_event({:web_login_started}),
    do: Marshall.Events.emit("ingress.web_login_started", [])

  defp emit_event({:web_login_approved, user_id, vm_id}),
    do: Marshall.Events.emit("ingress.web_login_approved", user_id: user_id, vm_id: vm_id)

  defp emit_event({:web_login_exchanged, vm_id}),
    do: Marshall.Events.emit("ingress.web_login_exchanged", vm_id: vm_id)
end
