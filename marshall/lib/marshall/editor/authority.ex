defmodule Marshall.Editor.Authority do
  @moduledoc "Fresh browser editor authority and single-use login exchange."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.{GuestAccount, GuestAccounts, Login, Security, User}
  alias Marshall.Access.Authorization
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Image, Ledger, VirtualMachine}
  alias Marshall.Editor.{Credential, Lease, Token}
  alias Marshall.Ingress.{Error, Execution, Service, Services}
  require Ash.Query
  require Marshall.Events

  @ttl 30_000

  @impl true
  def run(input, [operation: operation], %{actor: %User{} = actor})
      when operation in [:launch, :authorize_login] do
    Ledger.transaction(fn -> perform(operation, input.arguments, actor) end, actor)
    |> Error.result()
  end

  def run(input, [operation: operation], %{actor: %SystemActor{purpose: :compute}})
      when operation in [
             :begin_login,
             :exchange_login,
             :open_editor,
             :renew_editor,
             :close_editor
           ] do
    Ledger.transaction(fn -> perform(operation, input.arguments, nil) end) |> Error.result()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:security] editor-launch-current-identity
  # Launch MUST authorize current write access under the VM lock, allocate the
  # permanent guest identity for the stored User UUID, and refuse unsupported images.
  # The returned origin MUST encode the complete VM and GuestAccount UUIDs.
  @spec perform(atom(), map(), User.t() | nil) :: map()
  defp perform(:launch, request, actor) do
    vm = Ledger.lock!(VirtualMachine, request.vm_id) || deny!()
    unless vm.desired_state == :running and vm.observed_state == :running, do: deny!()
    capability!(vm)
    authorize!(vm, actor)
    account = GuestAccounts.ensure!(actor.id)
    authorize!(vm, actor)
    label = OverallsProtocol.EditorName.label(vm.id, account.id)
    %{hostname: hostname!(label), origin: origin!(label)}
  end

  defp perform(:begin_login, request, _) do
    service = Services.authenticate!(request.service_token, :exclusive)
    identity = identity!(request.label)
    {vm, host, now} = execution!(service, current_binding!(service, identity.vm_id))
    {_user, account} = current_account!(identity.guest_account_id)
    hash = state_digest!(request.state_digest)
    capacity!(Marshall.Editor.Login, service.id, now, 128)
    {ticket, token_hash} = Token.issue(:ticket)

    login =
      Ledger.create!(Marshall.Editor.Login, :record, %{
        token_hash: token_hash,
        state_hash: hash,
        service_id: service.id,
        service_generation: service.generation,
        vm_id: vm.id,
        host_id: host.id,
        placement_id: vm.current_placement_id,
        execution_epoch: vm.execution_epoch,
        generation: vm.generation,
        guest_account_id: account.id,
        label: request.label,
        expires_at: DateTime.add(now, 300)
      })

    outcome(:started, vm.id, nil)
    %{ticket: ticket, hostname: hostname!(login.label), expires_at: login.expires_at}
  end

  # @cc [owner:ghuntley,label:security;concurrency] editor-exchange-single-use
  # Approval and exchange MUST retain gateway/execution and exact account origin,
  # require the same current stored login and write authority, and consume a
  # matching code/state once atomically with cookie creation. A different user,
  # replay or retired account MUST refuse without consuming. Email changes MUST
  # preserve the same account origin and approval authority.
  defp perform(:authorize_login, request, actor) do
    {jti, expiry} =
      case Login.verify(request.login_token, actor) do
        {:ok, jti, expiry} -> {jti, expiry}
        _ -> Ledger.rollback(:authentication_required)
      end

    candidate = candidate!(Marshall.Editor.Login, request.ticket, :ticket)
    service = shared!(Service, id: candidate.service_id)
    {vm, _, _} = execution!(service, candidate)
    {user, account} = current_account!(candidate.guest_account_id)
    unless user.id == actor.id, do: Ledger.rollback(:forbidden)
    authorize!(vm, Security.bind(user, jti))
    login = Ledger.lock!(Marshall.Editor.Login, candidate.id) || deny!()
    live_login!(login, :pending)
    unless account.id == login.guest_account_id, do: deny!()
    {code, hash} = Token.issue(:code)

    Ledger.update!(login, :approve, %{
      code_hash: hash,
      user_id: user.id,
      login_jti: jti,
      expires_at: earlier(login.expires_at, earlier(expiry, DateTime.add(Ledger.now(), 60)))
    })

    outcome(:approved, vm.id, user.id)
    %{ticket: request.ticket, code: code, hostname: hostname!(login.label)}
  end

  defp perform(:exchange_login, request, _) do
    service = Services.authenticate!(request.service_token, :exclusive)
    candidate = candidate!(Marshall.Editor.Login, request.ticket, :ticket)
    service_binding!(candidate, service)
    {vm, _, now} = execution!(service, candidate)
    {user, account} = current_account!(candidate.guest_account_id)
    unless user.id == candidate.user_id, do: deny!()
    expiry = stored_login!(candidate.login_jti, user.id)
    authorize!(vm, Security.bind(user, candidate.login_jti))
    login = Ledger.lock!(Marshall.Editor.Login, candidate.id) || deny!()
    live_login!(login, :approved)
    unless Plug.Crypto.secure_compare(digest!(request.code, :code), login.code_hash), do: deny!()

    state_hash =
      case Base.url_decode64(request.state, padding: false) do
        {:ok, bytes} when byte_size(bytes) == 32 ->
          unless Base.url_encode64(bytes, padding: false) == request.state, do: deny!()
          :crypto.hash(:sha256, request.state)

        _ ->
          deny!()
      end

    unless Plug.Crypto.secure_compare(state_hash, login.state_hash), do: deny!()
    capacity!(Credential, service.id, now, 1024)
    {cookie, hash} = Token.issue(:cookie)

    credential =
      Ledger.create!(Credential, :record, %{
        token_hash: hash,
        user_id: user.id,
        login_jti: login.login_jti,
        guest_account_id: account.id,
        vm_id: vm.id,
        service_id: service.id,
        service_generation: service.generation,
        label: login.label,
        expires_at: earlier(expiry, DateTime.add(now, 43_200))
      })

    Ledger.update!(login, :consume, %{})
    outcome(:exchanged, vm.id, user.id)
    %{cookie: cookie, hostname: hostname!(login.label), expires_at: credential.expires_at}
  end

  defp perform(:open_editor, request, _) do
    service = Services.authenticate!(request.service_token, :exclusive)
    identity = identity!(request.label)
    {vm, host, now} = execution!(service, current_binding!(service, identity.vm_id))
    {user, account} = current_account!(identity.guest_account_id)
    unless is_binary(request[:cookie]), do: Ledger.rollback(:authentication_required)
    candidate = candidate!(Credential, request.cookie, :cookie)
    credential = credential!(candidate.id, service, vm, account, user, request.label)
    capacity!(Lease, service.id, now, 1024)
    {ticket, hash} = Token.issue(:lease)

    lease =
      Ledger.create!(
        Lease,
        :record,
        capability!(vm)
        |> Map.merge(%{
          token_hash: hash,
          service_id: service.id,
          service_generation: service.generation,
          vm_id: vm.id,
          host_id: host.id,
          placement_id: vm.current_placement_id,
          execution_epoch: vm.execution_epoch,
          generation: vm.generation,
          connection_session_id: host.connection_session_id,
          label: request.label,
          credential_id: credential.id,
          user_id: user.id,
          guest_account_id: account.id,
          uid: account.uid,
          username: account.username,
          editor_origin: origin!(request.label),
          expires_at: deadline!(vm, user, credential, now)
        })
      )

    outcome(:opened, vm.id, user.id)
    Map.put(view(lease), :ticket, ticket)
  end

  # @cc [owner:ghuntley,label:security] editor-renewal-cannot-migrate
  # Renewal MUST recheck live stored login, current write authority, permanent account,
  # host session and image descriptor before extending only expires_at. Expired,
  # closed or changed bindings MUST refuse, without allocating another identity.
  defp perform(:renew_editor, request, _) do
    service = Services.authenticate!(request.service_token, :exclusive)
    candidate = candidate!(Lease, request.stream_token, :lease)
    service_binding!(candidate, service)
    {vm, host, now} = execution!(service, candidate)
    {user, account} = current_account!(candidate.guest_account_id)
    credential = credential!(candidate.credential_id, service, vm, account, user, candidate.label)
    lease = Ledger.lock!(Lease, candidate.id) || deny!()

    unless is_nil(lease.closed_at) and DateTime.compare(lease.expires_at, now) == :gt and
             lease.connection_session_id == host.connection_session_id and
             lease.user_id == user.id and
             lease.uid == account.uid and lease.username == account.username and
             Map.take(lease, [:editor_protocol, :editor_commit, :editor_release]) ==
               capability!(vm) and
             lease.editor_origin == origin!(lease.label),
           do: deny!()

    lease |> Ledger.update!(:renew, %{expires_at: deadline!(vm, user, credential, now)}) |> view()
  end

  defp perform(:close_editor, request, _) do
    service = Services.authenticate!(request.service_token, :exclusive)
    candidate = candidate!(Lease, request.stream_token, :lease)
    service_binding!(candidate, service)
    lease = Ledger.lock!(Lease, candidate.id) || deny!()

    if is_nil(lease.closed_at) do
      Ledger.update!(lease, :close, %{closed_at: Ledger.now()})
      outcome(:closed, lease.vm_id, lease.user_id)
    end

    %{closed: true}
  end

  # @cc [owner:ghuntley,label:security;persistence] editor-permanent-account
  # Account resolution MUST lock User before GuestAccount, refuse retired users
  # and accounts, and preserve identity across email changes. A guest account
  # MUST belong to the locked User UUID; email spelling MUST NOT select identity.
  @spec current_account!(String.t()) :: {User.t(), GuestAccount.t()}
  defp current_account!(id) do
    candidate = List.first(Ledger.read!(GuestAccount, id: id)) || Ledger.rollback(:forbidden)

    user =
      User
      |> Ash.Query.for_read(:internal_lookup)
      |> Ash.Query.filter(id == ^candidate.user_id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one!(actor: SystemActor.compute()) || Ledger.rollback(:forbidden)

    account = shared!(GuestAccount, id: id)

    unless is_nil(user.deleted_at) and is_nil(account.retired_at) and
             account.user_id == user.id,
           do: Ledger.rollback(:forbidden)

    {user, account}
  end

  @spec authorize!(VirtualMachine.t(), User.t()) :: :ok
  defp authorize!(vm, actor) do
    stored_login!(Security.jti(actor), actor.id)

    unless OverallsProtocol.ProfilePolicy.allows?(vm.profile, :editor),
      do: Ledger.rollback(:forbidden)

    unless vm.profile != :customer or vm.owner_id == actor.id,
      do: Ledger.rollback(:forbidden)

    Authorization.require!(vm, actor, "write")
  end

  @spec execution!(Service.t(), map()) :: {VirtualMachine.t(), struct(), DateTime.t()}
  defp execution!(service, binding) do
    {vm, _, _} = result = Execution.current!(service, binding, :exclusive)

    unless OverallsProtocol.ProfilePolicy.allows?(vm.profile, :editor),
      do: Ledger.rollback(:forbidden)

    capability!(vm)
    result
  end

  @spec capability!(VirtualMachine.t()) :: Image.editor_capability()
  defp capability!(vm) do
    image = List.first(Ledger.read!(Image, id: vm.image_id)) || deny!()

    case Image.editor_capability(image, Application.get_env(:marshall, :ingress_editor_release)) do
      {:ok, capability} -> capability
      {:error, _} -> Ledger.rollback(:image_unavailable)
    end
  end

  @spec credential!(
          String.t(),
          Service.t(),
          VirtualMachine.t(),
          GuestAccount.t(),
          User.t(),
          String.t()
        ) :: Credential.t()
  defp credential!(id, service, vm, account, user, label) do
    credential = Ledger.lock!(Credential, id) || Ledger.rollback(:authentication_required)

    unless credential.service_id == service.id and
             credential.service_generation == service.generation and
             credential.vm_id == vm.id and credential.guest_account_id == account.id and
             credential.user_id == user.id and credential.label == label and
             is_nil(credential.revoked_at) and
             DateTime.compare(credential.expires_at, Ledger.now()) == :gt,
           do: Ledger.rollback(:authentication_required)

    stored_login!(credential.login_jti, user.id)
    authorize!(vm, Security.bind(user, credential.login_jti))
    credential
  end

  @spec deadline!(VirtualMachine.t(), User.t(), Credential.t(), DateTime.t()) :: DateTime.t()
  defp deadline!(vm, user, credential, now) do
    expiry = stored_login!(credential.login_jti, user.id)

    maximum =
      earlier(DateTime.add(now, @ttl, :millisecond), earlier(expiry, credential.expires_at))

    Authorization.deadline!(vm, Security.bind(user, credential.login_jti), "write", maximum)
  end

  @spec stored_login!(String.t() | nil, String.t()) :: DateTime.t()
  defp stored_login!(jti, user_id) when is_binary(jti) do
    case check_login(jti, user_id) do
      {:ok, expiry} -> expiry
      {:error, reason} -> Ledger.rollback(reason)
    end
  end

  defp stored_login!(_, _), do: Ledger.rollback(:authentication_required)

  # @cc [owner:ghuntley,label:security;reliability] editor-login-refusal-vs-unavailable
  # Only a definite stored-login refusal MUST require fresh authentication.
  # A failed or unreachable lookup MUST remain infrastructure unavailable;
  # neither result grants authority or revives a credential (ADR-0140).
  @doc false
  @spec check_login(String.t(), String.t()) ::
          {:ok, DateTime.t()} | {:error, :authentication_required | :unavailable}
  def check_login(jti, user_id) do
    case Login.check(jti, user_id) do
      {:ok, expiry} -> {:ok, expiry}
      :refused -> {:error, :authentication_required}
      :unavailable -> {:error, :unavailable}
    end
  end

  @spec current_binding!(Service.t(), String.t()) :: map()
  defp current_binding!(service, id) do
    vm = List.first(Ledger.read!(VirtualMachine, id: id)) || deny!()

    %{
      vm_id: vm.id,
      service_generation: service.generation,
      placement_id: vm.current_placement_id,
      execution_epoch: vm.execution_epoch,
      generation: vm.generation
    }
  end

  @spec identity!(String.t()) :: %{vm_id: String.t(), guest_account_id: String.t()}
  defp identity!(label) do
    case OverallsProtocol.EditorName.parse(label) do
      {:ok, identity} -> identity
      _ -> deny!()
    end
  end

  @spec candidate!(module(), String.t(), Token.purpose()) :: struct()
  defp candidate!(Credential, token, :cookie) do
    hash =
      case Token.digest(token, :cookie) do
        {:ok, hash} -> hash
        _ -> Ledger.rollback(:authentication_required)
      end

    List.first(Ledger.read!(Credential, token_hash: hash)) ||
      Ledger.rollback(:authentication_required)
  end

  defp candidate!(resource, token, purpose),
    do: List.first(Ledger.read!(resource, token_hash: digest!(token, purpose))) || deny!()

  @spec digest!(String.t(), Token.purpose()) :: binary()
  defp digest!(token, purpose) do
    case Token.digest(token, purpose) do
      {:ok, hash} -> hash
      _ -> deny!()
    end
  end

  @spec state_digest!(String.t()) :: binary()
  defp state_digest!(value) do
    case Base.decode16(value, case: :lower) do
      {:ok, hash} when byte_size(hash) == 32 -> hash
      _ -> deny!()
    end
  end

  @spec live_login!(Marshall.Editor.Login.t(), atom()) :: :ok
  defp live_login!(login, status) do
    unless login.status == status and DateTime.compare(login.expires_at, Ledger.now()) == :gt,
      do: deny!()

    :ok
  end

  @spec service_binding!(struct(), Service.t()) :: :ok
  defp service_binding!(record, service) do
    unless record.service_id == service.id and record.service_generation == service.generation and
             record.host_id == service.host_id,
           do: deny!()

    :ok
  end

  @spec capacity!(module(), String.t(), DateTime.t(), pos_integer()) :: :ok
  defp capacity!(resource, service_id, now, limit) do
    query = resource |> Ash.Query.filter(service_id == ^service_id and expires_at > ^now)
    if Ash.count!(query, actor: SystemActor.compute()) >= limit, do: Ledger.rollback(:capacity)
    :ok
  end

  @spec shared!(module(), keyword()) :: struct()
  defp shared!(resource, filter) do
    resource
    |> Ash.Query.filter(^filter)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one!(actor: SystemActor.compute()) || deny!()
  end

  @spec hostname!(String.t()) :: String.t()
  # @cc [owner:ghuntley,label:protocol;reliability] editor-origin-configured-zone
  # The authority MUST use the same canonical multi-label zone boundary as its
  # protocol and native broker. Invalid configuration MUST refuse before an
  # editor origin or credential is returned.
  defp hostname!(label) do
    zone = Application.fetch_env!(:marshall, :ingress_zone)
    unless OverallsProtocol.EditorConnect.zone?(zone), do: deny!()

    hostname = label <> "." <> zone
    unless byte_size(hostname) <= 253, do: deny!()
    hostname
  end

  @spec origin!(String.t()) :: String.t()
  defp origin!(label) do
    port = Application.get_env(:marshall, :ingress_https_port, 443)
    unless is_integer(port) and port in 1..65535, do: deny!()
    "https://" <> hostname!(label) <> if(port == 443, do: "", else: ":#{port}")
  end

  @spec view(Lease.t()) :: map()
  defp view(lease) do
    binding =
      Map.take(lease, [
        :vm_id,
        :host_id,
        :placement_id,
        :execution_epoch,
        :generation,
        :label,
        :user_id,
        :guest_account_id,
        :uid,
        :username,
        :editor_protocol,
        :editor_commit,
        :editor_release,
        :editor_origin
      ])
      |> Map.merge(%{session_id: lease.connection_session_id, service: :editor, port: 4444})

    %{
      binding: binding,
      user_id: lease.user_id,
      ttl: max(0, min(@ttl, DateTime.diff(lease.expires_at, Ledger.now(), :millisecond)))
    }
  end

  @spec outcome(atom(), String.t(), String.t() | nil) :: :ok
  defp outcome(kind, vm_id, user_id) do
    Ledger.after_commit(fn ->
      Marshall.Events.emit("editor.authority", kind: kind, vm_id: vm_id, user_id: user_id)
    end)
  end

  @spec earlier(DateTime.t(), DateTime.t()) :: DateTime.t()
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  @spec deny!() :: no_return()
  defp deny!, do: Ledger.rollback(:unauthorized)
end
