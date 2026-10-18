defmodule Marshall.SSH.Authority do
  @moduledoc "Transactional gateway, connection and browser-approval authority."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.SSH.{Approval, Gateway, Key, Session, Token}
  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;observability] ssh-audit-actor-classification
  # Trusted gateway configuration transactions MUST use operator audit context
  # and gateway runtime transactions system audit context, including any nested
  # PaperTrail writes. SystemActor remains solely the authorization principal.
  @impl true
  def run(input, options, context) do
    result =
      Ledger.transaction(
        fn -> perform(options[:operation], input.arguments, context.actor) end,
        audit_actor(options[:operation], context.actor)
      )

    with {:ok, {value, event}} <- result do
      unless Marshall.Repo.in_transaction?(), do: emit_event(event)
      {:ok, value}
    end
    |> Marshall.SSH.Error.result()
  end

  defp audit_actor(operation, %SystemActor{})
       when operation in [:configure_gateway, :ensure_gateway, :disable_gateway],
       do: :operator

  defp audit_actor(_operation, %SystemActor{}), do: :system
  defp audit_actor(_operation, actor), do: actor

  # @cc [owner:ghuntley,label:security;recovery] gateway-readiness-current-authority
  # Readiness MUST authenticate the current enabled gateway and require a writable
  # migrated database. It MUST NOT create sessions, approvals or machine work, or
  # return gateway/account details. It is a point-in-time observation, not a lease.
  defp perform(:gateway_ready, request, %SystemActor{purpose: :compute}) do
    gateway!(request.gateway_token)
    unless Marshall.Operations.Health.ready?(), do: Ledger.rollback(:temporarily_unavailable)
    {%{ready: true}, nil}
  end

  # @cc [owner:ghuntley,label:security;recovery] gateway-bootstrap-no-resurrection
  # Ensure MUST serialize with gateway configuration and either create absent
  # authority or retain the same enabled credential/generation. It MUST refuse
  # mismatched or disabled authority without rotating or re-enabling it. Explicit
  # operator configuration retains its separate credential-rotation semantics.
  defp perform(operation, request, %SystemActor{purpose: :compute})
       when operation in [:configure_gateway, :ensure_gateway] do
    digest = digest!(request.token, :gateway)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["ssh-gateway:" <> request.name],
      log: false
    )

    gateway =
      case Ledger.read!(Gateway, name: request.name) do
        [] ->
          Ledger.create!(Gateway, :record, %{name: request.name, token_hash: digest})

        [existing] ->
          gateway = Ledger.lock!(Gateway, existing.id)

          if gateway.enabled and gateway.token_hash == digest do
            gateway
          else
            if operation == :ensure_gateway, do: Ledger.rollback(:unauthorized)

            Ledger.update!(gateway, :rotate, %{
              token_hash: digest,
              generation: gateway.generation + 1,
              enabled: true
            })
          end
      end

    {Map.take(gateway, [:id, :name, :generation, :enabled]), {:gateway_configured, gateway.id}}
  end

  defp perform(:disable_gateway, %{id: id}, %SystemActor{purpose: :compute}) do
    case Ledger.lock!(Gateway, id) do
      nil ->
        Ledger.rollback(:gateway_not_found)

      gateway ->
        gateway =
          Ledger.update!(gateway, :rotate, %{enabled: false, generation: gateway.generation + 1})

        {Map.take(gateway, [:id, :name, :generation, :enabled]), {:gateway_disabled, gateway.id}}
    end
  end

  # @cc [owner:ghuntley,label:security] ssh-gateway-attested-proof
  # Only an authenticated gateway MAY open a connection. The gateway MUST call
  # this action only after verifying the SSH signature, never for a key probe.
  # Opening MUST serialize per-gateway active/pending limits and bind its current
  # credential generation. Public-key text alone MUST NOT authorize a user action.
  defp perform(:open, request, %SystemActor{purpose: :compute}) do
    gateway = gateway!(request.gateway_token, :for_update)

    parsed =
      case OverallsProtocol.SSHKey.parse(request.public_key) do
        {:ok, parsed} -> parsed
        _ -> Ledger.rollback(:invalid_public_key)
      end

    now = Ledger.now()

    active =
      Session
      |> Ash.Query.filter(gateway_id == ^gateway.id and is_nil(closed_at) and expires_at > ^now)

    if Ash.count!(active, actor: SystemActor.compute()) >= 4096,
      do: Ledger.rollback(:session_limit)

    key = Marshall.SSH.KeyRegistry.find(parsed)

    if key == nil and
         Ash.count!(Ash.Query.filter(active, is_nil(key_id)), actor: SystemActor.compute()) >= 256,
       do: Ledger.rollback(:approval_limit)

    {token, hash} = Token.issue(:session)

    session =
      Ledger.create!(Session, :record, %{
        token_hash: hash,
        gateway_id: gateway.id,
        gateway_generation: gateway.generation,
        key_id: if(key, do: key.id),
        expires_at:
          DateTime.add(
            now,
            if(key, do: 43_200, else: OverallsProtocol.SSHOnboarding.approval_ttl_seconds())
          )
      })

    if key do
      {Map.merge(status!(session), %{session_token: token}),
       {:session_opened, session.id, gateway.id}}
    else
      {approval_token, approval_hash} = Token.issue(:approval)

      Ledger.create!(Approval, :record, %{
        token_hash: approval_hash,
        session_id: session.id,
        public_key: parsed.public_key,
        fingerprint: parsed.fingerprint,
        expires_at: session.expires_at
      })

      {%{
         status: "pending",
         session_id: session.id,
         session_token: token,
         fingerprint: parsed.fingerprint,
         approval_path: "/ssh/approve/" <> approval_token,
         expires_at: session.expires_at
       }, {:session_opened, session.id, gateway.id}}
    end
  end

  defp perform(:status, request, %SystemActor{purpose: :compute}) do
    gateway = gateway!(request.gateway_token)
    session = session!(request.session_token, gateway)
    {status!(session), nil}
  end

  defp perform(:close, request, %SystemActor{purpose: :compute}) do
    gateway = gateway!(request.gateway_token)
    session = by_token!(Session, request.session_token, :session, :for_update)
    bind_gateway!(session, gateway)
    if session.closed_at == nil, do: Ledger.update!(session, :close, %{closed_at: Ledger.now()})
    {%{session_id: session.id, closed: true}, {:session_closed, session.id}}
  end

  defp perform(:inspect_approval, request, %Marshall.Accounts.User{}) do
    approval = by_token!(Approval, request.token, :approval, nil)
    gateway = approval |> session_gateway!() |> lock_gateway!()
    session = lock_session!(approval.session_id)
    bind_gateway!(session, gateway)
    live_session!(session)
    approval = Ledger.lock!(Approval, approval.id)
    fresh_approval!(approval)
    {%{fingerprint: approval.fingerprint, expires_at: approval.expires_at}, nil}
  end

  # @cc [owner:ghuntley,label:security;concurrency] ssh-approval-single-use
  # Approval MUST require a current browser actor and a live gateway-bound
  # connection, consume the token once under lock, and register through the same
  # owner-scoped Ash action as manual key addition. GET/inspection MUST NOT approve.
  defp perform(:approve_key, request, %Marshall.Accounts.User{} = user) do
    candidate = by_token!(Approval, request.token, :approval, nil)
    gateway = candidate |> session_gateway!() |> lock_gateway!()
    session = lock_session!(candidate.session_id)
    bind_gateway!(session, gateway)
    live_session!(session)
    approval = Ledger.lock!(Approval, candidate.id)
    fresh_approval!(approval)

    key =
      case Marshall.SSH.add_key(%{public_key: approval.public_key, label: request.label},
             actor: user
           ) do
        {:ok, key} -> key
        _ -> Ledger.rollback(:approval_unavailable)
      end

    live_session!(session)
    fresh_approval!(approval)

    Ledger.update!(session, :approve, %{
      key_id: key.id,
      expires_at: DateTime.add(Ledger.now(), 43_200)
    })

    Ledger.update!(approval, :consume, %{user_id: user.id, consumed_at: Ledger.now()})
    {%{approved: true, fingerprint: approval.fingerprint}, {:key_approved, session.id, key.id}}
  end

  defp perform(_, _, _), do: Ledger.rollback(:unauthorized)

  defp emit_event({:gateway_configured, gateway_id}),
    do: Marshall.Events.emit("ssh.gateway_configured", gateway_id: gateway_id)

  defp emit_event({:gateway_disabled, gateway_id}),
    do: Marshall.Events.emit("ssh.gateway_disabled", gateway_id: gateway_id)

  defp emit_event({:session_opened, session_id, gateway_id}),
    do: Marshall.Events.emit("ssh.session_opened", session_id: session_id, gateway_id: gateway_id)

  defp emit_event({:session_closed, session_id}),
    do: Marshall.Events.emit("ssh.session_closed", session_id: session_id)

  defp emit_event({:key_approved, session_id, key_id}),
    do: Marshall.Events.emit("ssh.key_approved", session_id: session_id, key_id: key_id)

  defp emit_event(nil), do: :ok

  # @cc [owner:ghuntley,label:security;concurrency] ssh-session-current-authority
  # Callers MUST retain the surrounding transaction through the domain command.
  # Every use MUST recheck gateway generation, expiry, closure and unarchived key
  # ownership. Shared locks MUST exclude concurrent revocation until admission.
  #
  # Only commands that may write (mutations, and identity allocation) serialize
  # on the account's advisory lock. Pure reads (status polls, listings) skip it:
  # they take only shared key/session locks, cannot form the revocation lock
  # cycle, and MUST NOT queue behind the same account's in-flight mutations
  # (ADR-0140). They still recheck gateway, session, key and user.
  @spec with_actor!(
          binary(),
          binary(),
          (Marshall.Accounts.User.t(), Session.t() -> result),
          boolean()
        ) :: result
        when result: term()
  def with_actor!(gateway_token, session_token, fun, serialize? \\ true) do
    unless Marshall.Repo.in_transaction?(), do: raise("SSH authority requires a transaction")
    gateway = gateway!(gateway_token)
    session = session!(session_token, gateway)
    if serialize?, do: serialize_commands!(session), else: approved!(session)
    {user, _key} = actor!(session)
    fun.(user, session)
  end

  defp approved!(%{key_id: nil}), do: Ledger.rollback(:approval_required)
  defp approved!(_session), do: :ok

  # @cc [owner:ghuntley,label:concurrency] ssh-command-key-lock-order
  # Commands for an account MUST serialize before taking authentication key locks,
  # so sessions using different keys can revoke each other's keys without a lock
  # upgrade cycle. The unlocked lookup MUST be followed by fresh actor validation.
  defp serialize_commands!(%{key_id: nil}), do: Ledger.rollback(:approval_required)

  defp serialize_commands!(session) do
    case Ledger.read!(Key, id: session.key_id) do
      [key] ->
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
          ["ssh:commands:" <> key.user_id],
          log: false
        )

      [] ->
        Ledger.rollback(:unauthorized)
    end
  end

  defp status!(session) do
    live_session!(session)

    if session.key_id == nil do
      %{status: "pending", session_id: session.id, expires_at: session.expires_at}
    else
      {user, _key} = actor!(session)

      %{
        status: "authenticated",
        session_id: session.id,
        expires_at: session.expires_at,
        user: %{id: user.id, email: to_string(user.email), locale: user.locale || "en"}
      }
    end
  end

  defp actor!(%{key_id: nil}), do: Ledger.rollback(:approval_required)

  defp actor!(session) do
    key =
      Key
      |> Ash.Query.filter(id == ^session.key_id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one!(actor: SystemActor.compute())

    if key == nil, do: Ledger.rollback(:unauthorized)

    user =
      Marshall.Accounts.User
      |> Ash.Query.for_read(:internal_lookup)
      |> Ash.Query.filter(id == ^key.user_id)
      |> Ash.read_one!(actor: SystemActor.compute())

    if user == nil or not is_nil(user.deleted_at), do: Ledger.rollback(:unauthorized)
    live_session!(session)
    {user, key}
  end

  defp session!(token, gateway) do
    session = by_token!(Session, token, :session, "FOR SHARE")
    bind_gateway!(session, gateway)
    live_session!(session)
    session
  end

  @doc """
  The enabled gateway a credential names, read under the same share lock as
  every gateway action; used to bind a control socket (ADR-0142).
  """
  @spec gateway_identity(binary()) ::
          {:ok, %{id: String.t(), generation: pos_integer()}} | {:error, term()}
  def gateway_identity(token) when is_binary(token) do
    Ledger.transaction(fn ->
      gateway = gateway!(token)
      %{id: gateway.id, generation: gateway.generation}
    end)
  end

  @spec authenticate_gateway!(binary()) :: Gateway.t()
  def authenticate_gateway!(token) do
    unless Marshall.Repo.in_transaction?(),
      do: raise("Gateway authentication requires a transaction")

    gateway!(token)
  end

  defp gateway!(token, lock \\ "FOR SHARE") do
    gateway = by_token!(Gateway, token, :gateway, lock)
    if not gateway.enabled, do: Ledger.rollback(:unauthorized)
    gateway
  end

  defp lock_gateway!(id) do
    gateway =
      Gateway
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one!(actor: SystemActor.compute())

    if gateway == nil or not gateway.enabled, do: Ledger.rollback(:approval_unavailable)
    gateway
  end

  defp session_gateway!(approval) do
    case Ledger.read!(Session, id: approval.session_id) do
      [session] -> session.gateway_id
      _ -> Ledger.rollback(:approval_unavailable)
    end
  end

  defp lock_session!(id) do
    Ledger.lock!(Session, id) || Ledger.rollback(:approval_unavailable)
  end

  defp bind_gateway!(session, gateway) do
    if session.gateway_id != gateway.id or session.gateway_generation != gateway.generation,
      do: Ledger.rollback(:unauthorized)
  end

  defp live_session!(session) do
    if session.closed_at != nil or DateTime.compare(session.expires_at, Ledger.now()) != :gt,
      do: Ledger.rollback(:unauthorized)
  end

  defp fresh_approval!(approval) do
    if approval == nil or approval.consumed_at != nil or
         DateTime.compare(approval.expires_at, Ledger.now()) != :gt,
       do: Ledger.rollback(:approval_unavailable)
  end

  defp by_token!(resource, token, purpose, lock) do
    hash = digest!(token, purpose)
    query = resource |> Ash.Query.filter(token_hash == ^hash)
    query = if lock, do: Ash.Query.lock(query, lock), else: query
    Ash.read_one!(query, actor: SystemActor.compute()) || Ledger.rollback(:unauthorized)
  end

  defp digest!(token, purpose) do
    case Token.digest(token, purpose) do
      {:ok, digest} -> digest
      :error -> Ledger.rollback(:unauthorized)
    end
  end
end
