defmodule Porsche.Terminal.AttachmentTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.TerminalAttach
  alias OverallsProtocol.WebSocket.{Frame, Handshake}

  @id "11111111-1111-4111-8111-111111111111"
  @session "22222222-2222-4222-8222-222222222222"
  @token "porsche_session_" <> Base.url_encode64(<<7::256>>, padding: false)
  @gateway "porsche_gateway_" <> Base.url_encode64(<<9::256>>, padding: false)
  @ticket "ticket-" <> Base.url_encode64(<<5::256>>, padding: false)
  @limit 1_048_576

  setup do
    directory =
      Path.join(System.tmp_dir!(), "porsche-attach-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
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

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, gateway_port} = :inet.port(listen)
    on_exit(fn -> :gen_tcp.close(listen) end)
    backend = start_supervised!({Agent, fn -> %{reply: :ticket, calls: []} end})
    {:ok, client} = Porsche.Client.new("https://marshall.test", @gateway)
    test = self()

    connect = fn _client, path, headers ->
      send(test, {:gateway_connect, path, headers})

      OverallsProtocol.WebSocket.Connection.open("http://127.0.0.1:#{gateway_port}", path,
        headers: headers,
        allow_insecure_loopback: true,
        timeout: 5000
      )
    end

    listener =
      start_supervised!(
        {Porsche.Listener,
         [
           port: 0,
           bind: {127, 0, 0, 1},
           host_key_dir: directory,
           key_cb: {Overalls.TestSSHKeyCallback, [proof: Porsche.SSH.Proof]},
           client: client,
           public_origin: "https://marshall.test",
           terminal_connect: connect,
           request: fn _, route, message, _ ->
             Agent.get_and_update(backend, fn state ->
               {reply(route, message, state), %{state | calls: state.calls ++ [{route, message}]}}
             end)
           end
         ]}
      )

    %{
      directory: directory,
      port: Porsche.Listener.port(listener),
      backend: backend,
      listen: listen
    }
  end

  test "attach without a prior pty request refuses before requesting a ticket", c do
    connection = connect(c)
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :success = :ssh_connection.exec(connection, channel, "terminal attach dev #{@session}", 5000)
    result = collect(connection, channel)
    assert result.status == 2
    assert result.out == ""
    assert {:ok, {:refused, :attach_requires_pty}} = TerminalAttach.decode(result.err)
    refute Enum.any?(calls(c), &match?({"commands", _}, &1))
  end

  test "interactive and structured dispatch refuse attach without contacting Marshall" do
    {:ok, client} = Porsche.Client.new("https://marshall.test", @gateway)

    result =
      Porsche.Runner.run(client, @token, "terminal attach dev #{@session} --json",
        request: fn _, _, _, _ -> flunk("attach must not reach the command runner") end
      )

    assert result.exit_status == 2
    assert result.response["error"] == "attach_requires_pty"
    Gettext.put_locale(Porsche.Gettext, "en")
    assert Porsche.SSH.Output.render(result.response, false) =~ "ssh -t"
  end

  test "a writable attach relays output after delivery, input within credit and resizes", c do
    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        {connection, channel} = attach(c, "terminal attach dev #{@session} --cursor 5")
        assert_receive {:gateway_connect, path, headers}, 5000
        assert path == "/api/terminal-gateway/v1/stream?cursor=5&cols=100&rows=30"

        assert Enum.sort(headers) ==
                 Enum.sort([
                   {"authorization", "Bearer " <> @gateway},
                   {TerminalAttach.session_header(), @token},
                   {TerminalAttach.ticket_header(), @ticket}
                 ])

        socket = accept(c.listen)

        push(socket, {:text, attached(5, 3, "rw")})
        header = stderr(connection, channel)

        assert {:ok, {:attached, %{from: 5, replay_bytes: 3, mode: :rw}}} =
                 TerminalAttach.decode(header)

        # Every output frame is acknowledged cumulatively, after delivery.
        for index <- 1..20 do
          push(socket, {:binary, "out-#{index}|"})
          assert stdout(connection, channel) == "out-#{index}|"

          assert %{"op" => "output_ack", "frames" => ^index, "bytes" => bytes} =
                   text(socket)

          assert bytes == Enum.sum(for i <- 1..index, do: byte_size("out-#{i}|"))
        end

        # Sixteen unacknowledged input frames exhaust the window; the
        # seventeenth waits for a receipt.
        for index <- 1..17, do: :ok = :ssh_connection.send(connection, channel, "in-#{index}")
        received = for _ <- 1..16, do: binary_frame(socket)
        assert received == for(index <- 1..16, do: "in-#{index}")
        assert silent(socket, 300)
        bytes = received |> Enum.map(&byte_size/1) |> Enum.sum()
        push(socket, {:text, JSON.encode!(%{op: "input_ack", frames: 16, bytes: bytes})})
        assert binary_frame(socket) == "in-17"

        :ok = :ssh_connection.window_change(connection, channel, 120, 40)
        assert %{"op" => "resize", "cols" => 120, "rows" => 40} = text(socket)

        push(socket, {:close, 1000, ""})
        result = collect(connection, channel)
        assert result.status == 0
        refute result.out =~ @ticket
        refute result.err =~ @ticket
      end)

    refute logs =~ "out-"
    refute logs =~ "in-1"
    refute logs =~ @ticket
    refute logs =~ @token
  end

  test "a read-only attach never sends input or resizes, even if granted writable", c do
    {connection, channel} = attach(c, "terminal attach dev #{@session} --read-only")
    socket = accept(c.listen)
    push(socket, {:text, attached(0, 0, "rw")})

    assert {:ok, {:attached, %{mode: :ro}}} =
             TerminalAttach.decode(stderr(connection, channel))

    for _ <- 1..40,
        do: :ok = :ssh_connection.send(connection, channel, String.duplicate("x", 4096))

    :ok = :ssh_connection.window_change(connection, channel, 120, 40)
    assert silent(socket, 500)
    push(socket, {:close, 1000, ""})
    assert collect(connection, channel).status == 0
  end

  test "client EOF detaches with a normal close and exit zero", c do
    {connection, channel} = attach(c, "terminal attach dev #{@session}")
    socket = accept(c.listen)
    push(socket, {:text, attached(0, 0, "rw")})
    _ = stderr(connection, channel)
    :ok = :ssh_connection.send_eof(connection, channel)
    assert {:close, 1000, _} = next_frame(socket)
    assert collect(connection, channel).status == 0
  end

  # @cc [owner:ghuntley,label:verification;protocol] porsche-attach-exit-property
  # Each close code, upgrade status and ticket refusal ends the SSH channel
  # with exactly the TerminalAttach exit status and at most one header line.
  property "every ending maps to the closed exit-status table", c, test_cases: 20 do
    ending =
      draw(
        "ending",
        one_of([
          map(member_of([1000, 4001, 4003, 1008, 1011, 3000]), &{:close, &1}),
          map(member_of([400, 401, 403, 404, 500, 503]), &{:status, &1}),
          map(
            member_of([:unauthorized, :forbidden, :not_found, :transport_error]),
            &{:refusal, &1}
          )
        ])
      )

    Agent.update(c.backend, &%{&1 | reply: ending})
    {connection, channel} = attach(c, "terminal attach dev #{@session}", false)

    expected =
      case ending do
        {:close, code} ->
          socket = accept(c.listen, false)
          push(socket, {:text, attached(0, 0, "rw")})
          push(socket, {:close, code, ""})
          :gen_tcp.close(socket)
          TerminalAttach.close_outcome(code)

        {:status, status} ->
          refuse(c.listen, status)
          TerminalAttach.status_outcome(status)

        {:refusal, reason} ->
          TerminalAttach.error_outcome(refusal(reason))
      end

    result = collect(connection, channel)
    :ssh.close(connection)
    assert result.status == TerminalAttach.exit_status(expected)
    assert [_one] = String.split(result.err, "\n", trim: true)
    assert {:ok, _header} = TerminalAttach.decode(result.err)
    Agent.update(c.backend, &%{&1 | reply: :ticket})
  end

  defp refusal(:transport_error), do: :temporarily_unavailable
  defp refusal(reason), do: reason

  defp reply("sessions", _message, _state),
    do:
      {:ok,
       %{
         "status" => "authenticated",
         "session_id" => @id,
         "session_token" => @token,
         "expires_at" => "2099-01-01T00:00:00Z",
         "user" => %{"id" => @id, "email" => "owner@example.test"}
       }}

  defp reply("close", _message, _state), do: {:ok, %{"session_id" => @id, "closed" => true}}

  defp reply(
         "commands",
         %{"session_token" => @token, "command" => %{"command" => "terminal attach"}},
         state
       ) do
    case state.reply do
      {:refusal, reason} ->
        {:error, reason}

      _ ->
        {:ok,
         %{
           "version" => 1,
           "status" => "succeeded",
           "result" => %{"ticket" => @ticket, "session_id" => @session, "machine_id" => @id}
         }}
    end
  end

  defp attached(from, replay, mode),
    do:
      JSON.encode!(%{
        op: "attached",
        from: from,
        replay_bytes: replay,
        mode: mode,
        channel: 1,
        guest_session_id: 1
      })

  defp attach(c, command, cleanup \\ true) do
    connection = connect(c, cleanup)
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :success = :ssh_connection.ptty_alloc(connection, channel, [width: 100, height: 30], 5000)
    :success = :ssh_connection.exec(connection, channel, command, 5000)
    {connection, channel}
  end

  defp connect(c, cleanup \\ true) do
    {:ok, connection} =
      :ssh.connect(
        ~c"127.0.0.1",
        c.port,
        [
          user: ~c"ignored-account",
          user_dir: String.to_charlist(c.directory),
          silently_accept_hosts: true,
          save_accepted_host: false,
          user_interaction: false,
          auth_methods: ~c"publickey"
        ],
        5000
      )

    if cleanup, do: on_exit(fn -> :ssh.close(connection) end)
    connection
  end

  defp calls(c), do: Agent.get(c.backend, & &1.calls)

  defp stdout(connection, channel), do: data(connection, channel, 0)
  defp stderr(connection, channel), do: data(connection, channel, 1)

  defp data(connection, channel, stream) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, ^stream, bytes}} ->
        :ssh_connection.adjust_window(connection, channel, byte_size(bytes))
        bytes
    after
      5000 -> flunk("expected SSH stream #{stream} data")
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
      8000 -> flunk("SSH channel did not close")
    end
  end

  # A minimal server side of Marshall's gateway stream upgrade.
  defp accept(listen, cleanup \\ true) do
    {socket, key} = request(listen)

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
        "Sec-WebSocket-Accept: ",
        Handshake.accept(key),
        "\r\n\r\n"
      ])

    Process.put({:buffer, socket}, <<>>)
    if cleanup, do: on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp refuse(listen, status) do
    {socket, _key} = request(listen)
    :ok = :gen_tcp.send(socket, "HTTP/1.1 #{status} Refused\r\ncontent-length: 0\r\n\r\n")
    :gen_tcp.close(socket)
  end

  defp request(listen) do
    {:ok, socket} = :gen_tcp.accept(listen, 5000)
    head = read_head(socket, <<>>)

    [_, key] =
      Regex.run(~r/\r\nSec-WebSocket-Key: ([^\r]+)\r\n/i, head) || flunk("no websocket key")

    {socket, key}
  end

  defp read_head(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      read_head(socket, buffer <> data)
    end
  end

  defp push(socket, frame) do
    {:ok, data} = Frame.encode(frame, :server, @limit)
    :ok = :gen_tcp.send(socket, data)
  end

  defp next_frame(socket, timeout \\ 5000) do
    buffer = Process.get({:buffer, socket}, <<>>)

    case Frame.decode(buffer, :server, @limit) do
      {:ok, frame, rest} ->
        Process.put({:buffer, socket}, rest)
        frame

      :more ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, data} ->
            Process.put({:buffer, socket}, buffer <> data)
            next_frame(socket, timeout)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp text(socket) do
    assert {:text, text} = next_frame(socket)
    JSON.decode!(text)
  end

  defp binary_frame(socket) do
    assert {:binary, bytes} = next_frame(socket)
    bytes
  end

  defp silent(socket, timeout), do: next_frame(socket, timeout) == {:error, :timeout}
end
