defmodule Marshall.SharingSurfacesFixture do
  @moduledoc """
  Composed terminal/SSH/private-web sharing fixture plus per-surface probe
  helpers. Fixture rows live in the caller's SQL sandbox; the terminal relay is
  the recording synthetic stream and the browser endpoint is a local Bandit
  server. No helper consults Authorization.allowed? as an expectation source.
  """

  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress
  alias Marshall.Ingress.{Endpoint, Token}
  alias Marshall.TerminalAttachmentSocket, as: Socket
  alias Marshall.TerminalAttachmentStream, as: Stream

  import ExUnit.Assertions

  @type role :: :web | :viewer | :operator | :manager | :revoked

  @type permissions :: %{read: boolean(), write: boolean(), web: boolean()}

  @type fixture :: %{
          host: Marshall.Compute.Host.t(),
          vm: Marshall.Compute.VirtualMachine.t(),
          owner: Marshall.Accounts.User.t(),
          credential: Marshall.Compute.Credentials.Issued.t(),
          ziggy_token: String.t(),
          member: Marshall.Accounts.User.t(),
          member_key: Marshall.SSH.Key.t(),
          member_public: String.t(),
          member_token: String.t(),
          member_name: String.t(),
          service_token: String.t(),
          label: String.t(),
          session: Marshall.Terminal.Session.t(),
          stream: pid(),
          server: reference(),
          port: pos_integer()
        }

  @type lease :: %{ticket: String.t(), ttl: non_neg_integer(), binding: map()}

  # @cc [owner:ghuntley,label:verification;security] sharing-surface-role-table
  # The oracle table MUST be a pure function of the model role; it MUST NOT read
  # authorization answers. web-only membership lacks terminal/SSH read but keeps
  # private web admission; revoked membership loses every surface at once.
  @spec expected(role()) :: permissions()
  def expected(:viewer), do: %{read: true, write: false, web: true}
  def expected(:operator), do: %{read: true, write: true, web: true}
  def expected(:manager), do: %{read: true, write: true, web: true}
  def expected(:web), do: %{read: false, write: false, web: true}
  def expected(:revoked), do: %{read: false, write: false, web: false}

  @spec fixture() :: fixture()
  def fixture do
    # Disable leftovers from any earlier failed run in this shared checkout so
    # admission always lands on this fixture's fresh host.
    for host <- Ledger.read!(Marshall.Compute.Host),
        do: Ledger.update!(host, :configure, %{enabled: false})

    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {:ok, ziggy} = Marshall.Inference.Credentials.rotate(fixture.vm.host_id, 3600)
    stream = ExUnit.Callbacks.start_supervised!({Stream, fixture.host.id}, id: make_ref())
    member = Marshall.ComputeFixtures.user()
    member_public = key_text()
    {:ok, key} = Marshall.SSH.add_key(%{public_key: member_public}, actor: member)
    {service_token, _} = Token.issue()

    {:ok, _service} =
      Ingress.configure_service(
        %{
          name: "sharing-" <> Ash.UUID.generate(),
          role: :gateway,
          host_id: fixture.vm.host_id,
          token: service_token,
          addresses: ["192.0.2.13"]
        },
        actor: SystemActor.compute()
      )

    {:ok, _} =
      Ingress.publish_host_key(%{token: service_token, public_key: key_text()},
        actor: SystemActor.compute()
      )

    [endpoint] = Ledger.read!(Endpoint, vm_id: fixture.vm.id)

    {:ok, _} =
      Ingress.configure_endpoint(
        %{
          vm_id: fixture.vm.id,
          expected_revision: endpoint.policy_revision,
          primary_port: 8080,
          visibility: :private
        },
        actor: fixture.owner
      )

    {:ok, session} =
      Marshall.Terminal.Authority.open_session(
        fixture.vm,
        fixture.owner,
        "root",
        "xterm-256color"
      )

    member_token = Marshall.TerminalFixtures.user_token(member)
    {server, port} = server(member, member_token)

    %{
      host: fixture.host,
      vm: fixture.vm,
      owner: fixture.owner,
      credential: fixture.credential,
      ziggy_token: ziggy.id <> "." <> ziggy.secret,
      member: member,
      member_key: key,
      member_public: member_public,
      member_token: member_token,
      member_name: member_name(member),
      service_token: service_token,
      label: endpoint.label,
      session: session,
      stream: stream,
      server: server,
      port: port
    }
  end

  @spec server(Marshall.Accounts.User.t(), String.t()) :: {reference(), pos_integer()}
  defp server(actor, token) do
    id = make_ref()

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         plug: {Socket, %{actor: actor, token: token, observer: self()}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: id
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    {id, port}
  end

  @spec member_name(Marshall.Accounts.User.t()) :: String.t()
  def member_name(member) do
    {:ok, account} =
      Ledger.transaction(fn -> Marshall.Accounts.GuestAccounts.ensure!(member.id) end)

    account.username
  end

  @spec key_text() :: String.t()
  def key_text,
    do:
      "ssh-ed25519 " <>
        Base.encode64(<<11::32, "ssh-ed25519", 32::32, :crypto.strong_rand_bytes(32)::binary>>)

  # @cc [owner:ghuntley,label:verification] sharing-fixture-fresh-host
  # Every step MUST re-fresh the host report instead of freezing checks.
  @spec fresh_host(fixture()) :: :ok
  def fresh_host(c) do
    [host] = Ledger.read!(Marshall.Compute.Host, id: c.host.id)
    Ledger.update!(host, :report, %{reported_at: Ledger.now()})
    :ok
  end

  @spec grant(fixture(), role()) :: {:ok, Marshall.Access.Change.t()} | {:error, term()}
  def grant(c, role), do: Marshall.TerminalFixtures.grant(c, c.member, role)

  @spec share_terminal(fixture()) :: :ok | {:error, atom()}
  def share_terminal(c),
    do: Marshall.Terminal.Sharing.set(c.session, c.owner, to_string(c.member.email), :shared)

  @spec terminal_ticket(fixture()) :: {:ok, String.t()} | {:error, atom()}
  def terminal_ticket(c), do: Marshall.Terminal.Authority.ticket(c.session, c.member)

  @spec effects(fixture()) :: [Stream.effect()]
  def effects(c), do: Stream.effects(c.stream)

  @spec roster(fixture()) :: {:ok, map()} | {:error, term()}
  def roster(c),
    do: Marshall.SSH.GuestAccess.roster(c.ziggy_token, ssh_binding(c))

  @spec ssh_binding(fixture()) :: Marshall.TerminalFixtures.roster_binding()
  def ssh_binding(c), do: Marshall.TerminalFixtures.roster_binding(c.vm)

  @spec open_ssh(fixture()) :: {:ok, lease()} | {:error, term()}
  def open_ssh(c),
    do:
      Ingress.open_ssh(
        %{service_token: c.service_token, public_key: c.member_public, label: c.label},
        actor: SystemActor.compute()
      )

  @spec renew_ssh(fixture(), String.t()) :: {:ok, map()} | {:error, term()}
  def renew_ssh(c, ticket),
    do:
      Ingress.renew_ssh(%{service_token: c.service_token, session_token: ticket},
        actor: SystemActor.compute()
      )

  @spec close_ssh(fixture(), String.t()) :: {:ok, map()} | {:error, term()}
  def close_ssh(c, ticket),
    do:
      Ingress.close_ssh(%{service_token: c.service_token, session_token: ticket},
        actor: SystemActor.compute()
      )

  @spec renew_web(fixture(), String.t()) :: {:ok, map()} | {:error, term()}
  def renew_web(c, ticket),
    do:
      Ingress.renew_web(%{service_token: c.service_token, stream_token: ticket},
        actor: SystemActor.compute()
      )

  @spec close_web(fixture(), String.t()) :: {:ok, map()} | {:error, term()}
  def close_web(c, ticket),
    do:
      Ingress.close_web(%{service_token: c.service_token, stream_token: ticket},
        actor: SystemActor.compute()
      )

  @type login_fixture :: %{
          service_token: String.t(),
          label: String.t(),
          member: Marshall.Accounts.User.t(),
          member_token: String.t()
        }

  # @cc [owner:ghuntley,label:verification;security] sharing-web-real-login-exchange
  # Web admission probes MUST use the complete real login exchange (begin,
  # ordinary-member authorize, gateway exchange); skipped sheltering of deny
  # paths is forbidden.
  @spec approve_web(login_fixture()) :: {:ok, String.t()} | {:error, term()}
  def approve_web(c) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.encode16(:crypto.hash(:sha256, state), case: :lower)

    with {:ok, started} <-
           Ingress.begin_web_login(
             %{
               service_token: c.service_token,
               label: c.label,
               app_port: 0,
               state_digest: digest
             },
             actor: SystemActor.compute()
           ),
         {:ok, approved} <-
           Ingress.authorize_web_login(%{ticket: started.ticket, login_token: c.member_token},
             actor: c.member
           ),
         {:ok, exchanged} <-
           Ingress.exchange_web_login(
             %{
               service_token: c.service_token,
               ticket: started.ticket,
               code: approved.code,
               state: state
             },
             actor: SystemActor.compute()
           ) do
      {:ok, exchanged.cookie}
    end
  end

  @spec open_web(fixture(), String.t()) :: {:ok, lease()} | {:error, term()}
  def open_web(c, cookie),
    do:
      Ingress.open_web(
        %{service_token: c.service_token, label: c.label, app_port: 0, cookie: cookie},
        actor: SystemActor.compute()
      )

  @spec attach(fixture(), String.t(), non_neg_integer()) :: pos_integer()
  def attach(c, ticket, cursor) do
    client = Socket.connect(c.port, ticket, cursor)
    {1, attached} = Socket.frame(client)

    %{"op" => "attached", "channel" => channel, "mode" => "ro"} = JSON.decode!(attached)

    assert is_integer(channel) and channel > 0
    Socket.barrier(client)
    Socket.disconnect(client)
    channel
  end
end
