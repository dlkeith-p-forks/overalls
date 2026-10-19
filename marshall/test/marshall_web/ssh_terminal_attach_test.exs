defmodule MarshallWeb.SSHTerminalAttachTest do
  @moduledoc """
  Real Porsche SSH attach over verified TLS into the fleet listener's gateway
  stream and the production `Marshall.Terminal.Viewer` (ADR-0223). The host
  terminal stream is the recording synthetic stream: guest execution, shared
  native output and replay are covered only by the fleet machine test.
  """
  use Marshall.DataCase, async: false
  import Plug.Test
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.SSH
  alias Marshall.Terminal.{Ticket, Tickets, Viewer}
  alias Marshall.TerminalAttachmentStream, as: Stream
  alias OverallsProtocol.TerminalAttach

  @certificate Path.expand("../fixtures/tls/localhost.pem", __DIR__)
  @key Path.expand("../fixtures/tls/localhost.key", __DIR__)
  @ca Path.expand("../fixtures/tls/ca.pem", __DIR__)

  setup do
    for host <- Ledger.read!(Marshall.Compute.Host),
        do: Ledger.update!(host, :configure, %{enabled: false})

    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = start_supervised!({Stream, fixture.host.id}, id: make_ref())

    {:ok, terminal} =
      Marshall.Terminal.Authority.open_session(
        fixture.vm,
        fixture.owner,
        "root",
        "xterm-256color"
      )

    directory =
      Path.join(System.tmp_dir!(), "marshall-attach-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)

    for name <- ["ssh_host_ed25519_key", "id_ed25519"] do
      {_, 0} =
        System.cmd("ssh-keygen", [
          "-q",
          "-t",
          "ed25519",
          "-N",
          "",
          "-f",
          Path.join(directory, name)
        ])
    end

    public_key = File.read!(Path.join(directory, "id_ed25519.pub"))
    {:ok, key} = SSH.add_key(%{public_key: public_key}, actor: fixture.owner)
    {gateway, _} = SSH.Token.issue(:gateway)

    {:ok, _} =
      SSH.configure_gateway(%{name: "terminal-attach", token: gateway},
        actor: SystemActor.compute()
      )

    {:ok, _} = Application.ensure_all_started(:ssh)
    start_supervised!({Registry, keys: :unique, name: Porsche.SSH.Proofs})
    start_supervised!({Registry, keys: :unique, name: Porsche.SSH.Sessions})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: Porsche.SSH.Connections})
    start_supervised!({Task.Supervisor, name: Porsche.SSH.Commands})

    start_supervised!(
      {DynamicSupervisor, strategy: :one_for_one, name: Porsche.Terminal.Attachments}
    )

    on_exit(fn -> :logger.remove_primary_filter(:porsche_privacy) end)

    server =
      start_supervised!(
        {Bandit,
         [
           plug: MarshallWeb.FleetEndpoint,
           scheme: :https,
           ip: {127, 0, 0, 1},
           port: 0,
           certfile: @certificate,
           keyfile: @key,
           startup_log: false
         ]}
      )

    {:ok, {_, https_port}} = ThousandIsland.listener_info(server)
    origin = "https://127.0.0.1:#{https_port}"
    credential = Path.join(directory, "gateway")
    File.write!(credential, gateway)
    File.chmod!(credential, 0o400)
    ca = Path.join(directory, "ca.pem")
    File.cp!(@ca, ca)
    path = Path.join(directory, "config.json")

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "control_plane" => origin,
        "public_origin" => origin,
        "credential_file" => credential,
        "host_key_dir" => directory,
        "port" => free_port(),
        "bind" => "127.0.0.1",
        "cacertfile" => ca
      })
    )

    {:ok, [{Porsche.Control.Link, client}, {Porsche.Listener, options}]} =
      Porsche.Application.listener_children(path)

    client = control(client)

    listener =
      start_supervised!(
        {Porsche.Listener,
         options
         |> Keyword.put(:client, client)
         |> Keyword.put(:key_cb, {Overalls.TestSSHKeyCallback, [proof: Porsche.SSH.Proof]})}
      )

    Map.merge(fixture, %{
      directory: directory,
      port: Porsche.Listener.port(listener),
      key: key,
      public_key: public_key,
      gateway: gateway,
      stream: stream,
      terminal: terminal
    })
  end

  # @cc [owner:ghuntley,label:verification;security] ssh-attach-real-gateway-stream
  # The attach MUST traverse real Porsche SSH, the control-socket ticket
  # command and the fleet listener's gateway upgrade into the production
  # Viewer: output reaches SSH stdout only with returned credit, input and
  # resize reach the shared registry session, and no receipt pins the ticket.
  test "an SSH attach relays the shared session through the production viewer", c do
    {connection, channel} = attach(c, "terminal attach #{c.vm.id} #{c.terminal.id} --cursor 7")

    assert {:ok, {:attached, %{from: 7, mode: :rw}}} =
             TerminalAttach.decode(stderr(connection, channel))

    assert [{:attach, viewer, message}] = Stream.effects(c.stream)
    assert message.mode == :rw and message.cursor == 7
    assert {message.cols, message.rows} == {100, 30}
    assert message.guest_session_id == c.terminal.guest_session_id

    # Twenty frames exceed the sixteen-frame output window, so each one must
    # have been acknowledged by Porsche after its SSH delivery.
    for index <- 1..20 do
      send(viewer, {:terminal_output, "frame-#{index};"})
      assert stdout(connection, channel) == "frame-#{index};"
    end

    :ok = :ssh_connection.send(connection, channel, "echo shared\r")
    :ok = :ssh_connection.window_change(connection, channel, 120, 40)

    assert_eventually(fn ->
      effects = Stream.effects(c.stream)

      Enum.any?(effects, &match?({:input, _, "echo shared\r"}, &1)) and
        Enum.any?(effects, &match?({:resize, %{cols: 120, rows: 40}}, &1))
    end)

    send(viewer, {:terminal_closed, %{}})
    result = collect(connection, channel)
    assert result.status == 0
    assert Ledger.read!(SSH.Request) == []
    assert Ledger.read!(Ticket) == []
  end

  # @cc [owner:ghuntley,label:verification;security] ssh-attach-read-only-drops-input
  # A --read-only attach MUST attach read-only and MUST NOT deliver any input
  # or resize to the shared session.
  test "a read-only SSH attach never reaches the session with input", c do
    {connection, channel} = attach(c, "terminal attach #{c.vm.id} #{c.terminal.id} --read-only")

    assert {:ok, {:attached, %{mode: :ro}}} =
             TerminalAttach.decode(stderr(connection, channel))

    assert [{:attach, viewer, %{mode: :ro, cols: 0, rows: 0}}] = Stream.effects(c.stream)
    for _ <- 1..10, do: :ok = :ssh_connection.send(connection, channel, "rm -rf /tmp/x\r")
    :ok = :ssh_connection.window_change(connection, channel, 120, 40)
    send(viewer, {:terminal_output, "still-visible"})
    assert stdout(connection, channel) == "still-visible"
    Process.sleep(300)
    assert [{:attach, _, _}] = Stream.effects(c.stream)
    send(viewer, {:terminal_closed, %{}})
    assert collect(connection, channel).status == 0
  end

  # @cc [owner:ghuntley,label:verification;security;recovery] ssh-attach-revocation-closes
  # Removing the attaching key MUST close a live SSH attachment with the
  # authority exit status within the five-second recheck (plus margin), while
  # the shared terminal session stays alive.
  test "key revocation closes a live attachment with exit 3 within five seconds", c do
    {connection, channel} = attach(c, "terminal attach #{c.vm.id} #{c.terminal.id}")
    assert {:ok, {:attached, _}} = TerminalAttach.decode(stderr(connection, channel))
    revoked = System.monotonic_time(:millisecond)
    assert {:ok, _} = SSH.remove_key(%{id: c.key.id}, actor: c.owner)
    result = collect(connection, channel)
    elapsed = System.monotonic_time(:millisecond) - revoked
    assert result.status == TerminalAttach.exit_status(:authority)
    assert elapsed < 6500, "attachment closed #{elapsed}ms after revocation"
    assert [{:attach, _, _}, {:gone, _}] = Stream.effects(c.stream)
    [terminal] = Ledger.read!(Marshall.Terminal.Session, id: c.terminal.id)
    assert terminal.kill_status == :idle
  end

  test "a closed SSH session closes its attachment with exit 3", c do
    {connection, channel} = attach(c, "terminal attach #{c.vm.id} #{c.terminal.id}")
    assert {:ok, {:attached, _}} = TerminalAttach.decode(stderr(connection, channel))
    [session] = Enum.filter(Ledger.read!(SSH.Session), &is_nil(&1.closed_at))
    closed = System.monotonic_time(:millisecond)
    Ledger.update!(session, :close, %{closed_at: Ledger.now()})
    result = collect(connection, channel)
    assert result.status == TerminalAttach.exit_status(:authority)
    assert System.monotonic_time(:millisecond) - closed < 6500
  end

  test "an attach to another machine's or an unknown session is refused with exit 1", c do
    {connection, channel} = attach(c, "terminal attach #{c.vm.id} #{Ash.UUID.generate()}")
    result = collect(connection, channel)
    assert result.status == TerminalAttach.exit_status(:refused)
    assert {:ok, {:refused, :not_found}} = TerminalAttach.decode(result.err)
    assert result.out == ""
    assert Ledger.read!(Ticket) == []
  end

  # @cc [owner:ghuntley,label:verification;security] gateway-ticket-origin-binding
  # Browser tickets MUST NOT open gateway streams, SSH tickets MUST NOT open a
  # browser viewer or another SSH session's stream, and a refused credential
  # MUST close with the authority code before any ticket is consumed.
  test "tickets are bound to their origin and SSH session", c do
    {:ok, opened} =
      SSH.open_session(%{gateway_token: c.gateway, public_key: c.public_key},
        actor: SystemActor.compute()
      )

    {:ok, other} =
      SSH.open_session(%{gateway_token: c.gateway, public_key: c.public_key},
        actor: SystemActor.compute()
      )

    authority = {:ssh, c.gateway, opened.session_token}
    {:ok, browser} = Tickets.issue(c.terminal.id, c.owner.id, :ro)

    assert {:stop, :normal, 4003, %{}} =
             Viewer.init(%{ticket: browser, authority: authority, cursor: 0})

    {:ok, foreign} = Tickets.issue(c.terminal.id, c.owner.id, :ro, other.session_id)

    assert {:stop, :normal, 4003, %{}} =
             Viewer.init(%{ticket: foreign, authority: authority, cursor: 0})

    {:ok, ssh} = Tickets.issue(c.terminal.id, c.owner.id, :ro, opened.session_id)
    {:ok, jti, _} = Marshall.Accounts.Login.verify(c.token, c.owner)

    assert {:stop, :unauthorized, %{}} =
             Viewer.init(%{ticket: ssh, actor: c.owner, cursor: 0, login_jti: jti})

    {:ok, unused} = Tickets.issue(c.terminal.id, c.owner.id, :ro, opened.session_id)
    bad = {:ssh, c.gateway, "porsche_session_" <> Base.url_encode64(<<0::256>>, padding: false)}
    assert {:stop, :normal, 4001, %{}} = Viewer.init(%{ticket: unused, authority: bad, cursor: 0})
    assert {:ok, %{ssh_session_id: id}} = Tickets.consume(unused)
    assert id == opened.session_id
  end

  test "the gateway upgrade refuses before any socket exists", c do
    {:ok, opened} =
      SSH.open_session(%{gateway_token: c.gateway, public_key: c.public_key},
        actor: SystemActor.compute()
      )

    path = TerminalAttach.path()
    ticket = String.duplicate("t", 43)

    request = fn conn_scheme, headers, query ->
      conn(:get, path <> query)
      |> Map.put(:scheme, conn_scheme)
      |> then(fn conn ->
        Enum.reduce(headers, conn, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
      end)
      |> MarshallWeb.FleetEndpoint.call([])
    end

    good = [
      {"authorization", "Bearer " <> c.gateway},
      {TerminalAttach.session_header(), opened.session_token},
      {TerminalAttach.ticket_header(), ticket}
    ]

    assert request.(:http, good, "").status == 404
    assert request.(:https, tl(good), "").status == 401

    assert request.(:https, List.replace_at(good, 0, {"authorization", "Bearer x"}), "").status ==
             401

    unknown = "porsche_session_" <> Base.url_encode64(<<1::256>>, padding: false)

    assert request.(
             :https,
             List.replace_at(good, 1, {TerminalAttach.session_header(), unknown}),
             ""
           ).status ==
             401

    assert request.(:https, good, "?cursor=-1").status == 400
    assert request.(:https, good, "?cols=80").status == 400
    assert request.(:https, good, "?ticket=x").status == 400

    refused = request.(:https, [], "")
    assert refused.status == 401
    assert refused.resp_body == ""
    assert Plug.Conn.get_resp_header(refused, "cache-control") == ["no-store"]
  end

  defp attach(c, command) do
    connection = connect(c)
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :success = :ssh_connection.ptty_alloc(connection, channel, [width: 100, height: 30], 5000)
    :success = :ssh_connection.exec(connection, channel, command, 5000)
    {connection, channel}
  end

  defp connect(c) do
    {:ok, connection} =
      :ssh.connect(
        ~c"127.0.0.1",
        c.port,
        [
          user: ~c"untrusted-username",
          user_dir: String.to_charlist(c.directory),
          silently_accept_hosts: true,
          save_accepted_host: false,
          user_interaction: false,
          auth_methods: ~c"publickey"
        ],
        5000
      )

    on_exit(fn -> :ssh.close(connection) end)
    connection
  end

  defp stdout(connection, channel), do: data(connection, channel, 0)
  defp stderr(connection, channel), do: data(connection, channel, 1)

  defp data(connection, channel, stream) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, ^stream, bytes}} ->
        :ssh_connection.adjust_window(connection, channel, byte_size(bytes))
        bytes
    after
      10_000 -> flunk("expected SSH stream #{stream} data")
    end
  end

  defp collect(connection, channel, result \\ %{out: "", err: "", status: nil}) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, stream, bytes}} ->
        :ssh_connection.adjust_window(connection, channel, byte_size(bytes))
        key = if stream == 0, do: :out, else: :err
        collect(connection, channel, Map.update!(result, key, &(&1 <> bytes)))

      {:ssh_cm, ^connection, {:exit_status, ^channel, status}} ->
        collect(connection, channel, %{result | status: status})

      {:ssh_cm, ^connection, {:eof, ^channel}} ->
        collect(connection, channel, result)

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        result
    after
      12_000 -> flunk("SSH attach did not finish")
    end
  end

  defp assert_eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && assert_eventually(fun, attempts - 1)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  @spec control(Porsche.Client.t()) :: Porsche.Client.t()
  defp control(client) do
    client = %{client | control: :"porsche_attach_#{System.unique_integer([:positive])}"}
    start_supervised!({Porsche.Control.Link, client}, id: client.control)

    Enum.reduce_while(1..50, :ok, fn _, :ok ->
      if OverallsProtocol.Control.Client.ready?(client.control),
        do: {:halt, :ok},
        else: (Process.sleep(20) && {:cont, :ok}) || {:cont, :ok}
    end)

    client
  end
end
