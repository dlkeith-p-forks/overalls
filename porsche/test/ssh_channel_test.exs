defmodule Porsche.SSH.ChannelTest do
  use ExUnit.Case, async: false
  @id "11111111-1111-4111-8111-111111111111"
  @token "porsche_session_" <> Base.url_encode64(<<0::256>>, padding: false)

  setup context do
    directory =
      Path.join(System.tmp_dir!(), "porsche-channel-#{System.unique_integer([:positive])}")

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

    backend =
      start_supervised!(
        {Agent,
         fn ->
           %{approved: context[:pending] != true, completed: false, calls: []}
         end}
      )

    {:ok, client} =
      Porsche.Client.new(
        "https://marshall.test",
        "porsche_gateway_" <> Base.url_encode64(<<0::256>>, padding: false)
      )

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
           request: fn _, route, message, _ ->
             Agent.get_and_update(backend, fn state ->
               {backend_reply(route, message, state),
                %{state | calls: state.calls ++ [{route, message}]}}
             end)
           end
         ]}
      )

    %{
      directory: directory,
      port: Porsche.Listener.port(listener),
      backend: backend,
      client: client,
      listener: listener
    }
  end

  test "readiness requires a live listener and an exact affirmative control reply", c do
    assert Porsche.Health.ready?(c.client, c.listener,
             request: fn _, "ready", %{"version" => 1}, [timeout: 5000] ->
               {:ok, %{"ready" => true}}
             end
           )

    for reply <- [
          {:ok, %{"ready" => false}},
          {:ok, %{"ready" => true, "extra" => 1}},
          {:error, :unauthorized},
          {:error, :transport_error}
        ] do
      refute Porsche.Health.ready?(c.client, c.listener, request: fn _, _, _, _ -> reply end)
    end

    :ok = stop_supervised(Porsche.Listener)

    refute Porsche.Health.ready?(c.client, c.listener,
             request: fn _, _, _, _ ->
               send(self(), :unexpected_readiness_request)
               {:ok, %{"ready" => true}}
             end
           )

    refute_received :unexpected_readiness_request
  end

  test "OpenSSH exec gets one JSON stdout result and a meaningful exit status", context do
    {stdout, stderr, status} = openssh(context, ["whoami --json"])
    assert status == 0

    assert %{"status" => "succeeded", "result" => %{"email" => "owner@example.test"}} =
             JSON.decode!(stdout)

    refute stderr =~ "owner@example.test"
    {stdout, _, status} = openssh(context, ["uname -a"])
    assert status == 2
    assert stdout == "Invalid command. Type help to see available commands.\n"
  end

  test "exec reads integration secrets from stdin without placing them in command arguments",
       context do
    connection = connect(context)
    secret = "stdin-only-secret"

    result =
      exec_with_stdin(
        connection,
        "integration add private-api --target https://api.example.test --bearer - --json",
        secret <> "\n"
      )

    assert result.status == 0
    refute result.out =~ secret
    refute result.err =~ secret

    assert Enum.any?(calls(context), fn
             {"commands", %{"command" => %{"command" => "integration add", "options" => options}}} ->
               options["bearer"] == secret

             _ ->
               false
           end)
  end

  test "channels share one connection session and keep progress on stderr", context do
    connection = connect(context)
    result = exec(connection, "new --no-wait --request-id native-test --json")
    assert result.status == 0
    assert %{"status" => "accepted", "request_id" => "native-test"} = JSON.decode!(result.out)
    assert result.err =~ "Request native-test: submitting"
    Agent.update(context.backend, &%{&1 | completed: true})
    result = exec(connection, "request show native-test --json")
    assert %{"status" => "succeeded"} = JSON.decode!(result.out)
    assert length(Enum.filter(calls(context), &(elem(&1, 0) == "sessions"))) == 1
  end

  @tag pending: true
  test "unknown-key exec returns approval instructions without submitting the command", context do
    connection = connect(context)
    result = exec(connection, "new --no-wait --json")
    assert result.status == 3
    assert %{"status" => "approval_required", "approval_url" => url} = JSON.decode!(result.out)
    assert String.starts_with?(url, "https://marshall.test/ssh/approve/")
    refute Enum.any?(calls(context), &(elem(&1, 0) == "commands"))
  end

  @tag pending: true
  test "unknown-key human exec directs users to an interactive connection", context do
    connection = connect(context)
    result = exec(connection, "new --no-wait")
    assert result.status == 3
    assert result.out =~ "We don't recognize this SSH key"
    assert result.out =~ "ssh marshall.test"
    assert result.out =~ "Keep that connection open"
    refute result.out =~ "/ssh/approve/"
    refute Enum.any?(calls(context), &(elem(&1, 0) == "commands"))
  end

  @tag pending: true
  test "the interactive prompt continues after approval and handles pipelined lines", context do
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :ok = :ssh_connection.shell(connection, channel)
    banner = until_prompt(connection, channel, "")
    assert banner =~ "We don't recognize this SSH key"
    assert banner =~ "https://marshall.test/ssh/approve/"
    assert banner =~ "Keep this SSH connection open"
    Agent.update(context.backend, &%{&1 | approved: true})
    :ok = :ssh_connection.send(connection, channel, "whoami --json\nexit\n")
    result = collect(connection, channel, %{out: "", err: "", status: nil})
    assert result.out =~ "owner@example.test"
    assert result.status == 0
    assert Enum.count(calls(context), &(elem(&1, 0) == "sessions")) == 1
  end

  test "SFTP and direct TCP forwarding are unavailable", context do
    {_, errors, status} = openssh(context, ["sftp"], ["-s"])
    assert status != 0
    assert errors =~ "subsystem request failed"
    {_, errors, status} = openssh(context, [], ["-W", "127.0.0.1:22"])
    assert status != 0
    assert errors =~ "Forwarding disabled"
    refute Enum.any?(calls(context), &(elem(&1, 0) == "commands"))
  end

  @tag pending: true
  test "PTY approval and results return to column zero without doubling echoed CRLF", context do
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :success = :ssh_connection.ptty_alloc(connection, channel, [], 5000)
    :ok = :ssh_connection.shell(connection, channel)
    banner = until_prompt(connection, channel, "")
    assert banner =~ "help.\r\nDocs: "
    assert banner =~ "After approval, retry your command here.\r\n"
    refute banner =~ ~r/(?<!\r)\n/
    refute banner =~ "\r\r\n"
    Agent.update(context.backend, &%{&1 | approved: true})
    :ok = :ssh_connection.send(connection, channel, "who")
    assert_receive {:ssh_cm, ^connection, {:data, ^channel, 0, "\r\e[J"}}
    assert_receive {:ssh_cm, ^connection, {:data, ^channel, 0, "porsche> who"}}
    refute_receive {:ssh_cm, ^connection, {:data, ^channel, 0, "porsche> "}}
    :ok = :ssh_connection.send(connection, channel, "ami --json\r\n")
    result = until_prompt(connection, channel, "")
    assert result =~ "owner@example.test"
    assert result =~ "whoami --json\r\n"
    refute result =~ ~r/(?<!\r)\n/
    refute result =~ "\r\r\n"

    assert Enum.count(calls(context), fn
             {"commands", %{"command" => %{"command" => "whoami"}}} -> true
             _ -> false
           end) == 1
  end

  test "abrupt listener death does not leave the old daemon serving connections", context do
    connection = connect(context)
    assert exec(connection, "whoami --json").status == 0
    Process.exit(context.listener, :kill)
    await_closed(connection, 100)
  end

  defp await_closed(_connection, 0), do: flunk("orphaned SSH daemon retained the connection")

  defp await_closed(connection, attempts) do
    case :ssh.connection_info(connection) do
      {:error, _} ->
        :ok

      _ ->
        Process.sleep(20)
        await_closed(connection, attempts - 1)
    end
  end

  test "physical exec waits for a terminal receipt while channel close never cancels admission",
       context do
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)

    :success =
      :ssh_connection.exec(connection, channel, "new --request-id waiting-test --json", 5000)

    assert_receive {:ssh_cm, ^connection, {:data, ^channel, 1, progress}}, 5000
    assert progress =~ "submitting"
    Agent.update(context.backend, &%{&1 | completed: true})
    result = collect(connection, channel, %{out: "", err: "", status: nil})
    assert %{"status" => "succeeded", "request_id" => "waiting-test"} = JSON.decode!(result.out)
    assert result.status == 0

    Agent.update(context.backend, &%{&1 | completed: false})
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)

    :success =
      :ssh_connection.exec(connection, channel, "new --request-id detached-test --json", 5000)

    wait_for_waiting(connection, channel)
    workers = Task.Supervisor.children(Porsche.SSH.Commands)
    assert length(workers) == 1
    references = Enum.map(workers, &Process.monitor/1)
    :ok = :ssh_connection.close(connection, channel)
    for reference <- references, do: assert_receive({:DOWN, ^reference, :process, _, _}, 5000)

    assert Enum.count(calls(context), fn
             {"commands",
              %{
                "command" => %{
                  "command" => "new",
                  "options" => %{"request-id" => "detached-test"}
                }
              }} ->
               true

             _ ->
               false
           end) == 1

    # The same connection remains usable and the accepted receipt remains queryable.
    assert %{"status" => "accepted"} =
             exec(connection, "request show detached-test --json").out |> JSON.decode!()
  end

  defp wait_for_waiting(connection, channel) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, 1, bytes}} ->
        if not String.contains?(bytes, "waiting for completion"),
          do: wait_for_waiting(connection, channel)
    after
      5000 -> flunk("physical command did not begin waiting")
    end
  end

  test "interactive input is bounded and EOF executes a final complete line", context do
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :ok = :ssh_connection.shell(connection, channel)
    until_prompt(connection, channel, "")
    :ok = :ssh_connection.send(connection, channel, "whoami --json")
    :ok = :ssh_connection.send_eof(connection, channel)

    assert collect(connection, channel, %{out: "", err: "", status: nil}).out =~
             "owner@example.test"

    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :ok = :ssh_connection.shell(connection, channel)
    until_prompt(connection, channel, "")
    :ok = :ssh_connection.send(connection, channel, String.duplicate("x", 8193))
    result = collect(connection, channel, %{out: "", err: "", status: nil})
    assert result.status == 2
    assert result.out =~ "command_too_large"
  end

  test "fragmented arrows edit on the wire and history is isolated per channel", context do
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :success = :ssh_connection.ptty_alloc(connection, channel, [], 5000)
    :ok = :ssh_connection.shell(connection, channel)
    banner = until_prompt(connection, channel, "")
    assert String.starts_with?(banner, " _   _ _   _\r\n")
    assert banner =~ "|_\\_\\_|\\__|\\__\\___|_||_/__/\r\n\r\nPorsche"
    assert length(String.split(banner, " _   _ _   _")) == 2

    for bytes <- ["whoai", "\e", "[", "D", "m", "\eO", "C", " --json\r\n"] do
      :ok = :ssh_connection.send(connection, channel, bytes)
    end

    result = until_text(connection, channel, "owner@example.test", "")
    until_prompt(connection, channel, result)
    before = command_count(context)
    :ok = :ssh_connection.send(connection, channel, "\e[A")
    until_text(connection, channel, "porsche> whoami --json", "")
    Process.sleep(100)
    assert command_count(context) == before

    {:ok, other} = :ssh_connection.session_channel(connection, 5000)
    :success = :ssh_connection.ptty_alloc(connection, other, [], 5000)
    :ok = :ssh_connection.shell(connection, other)
    until_prompt(connection, other, "")
    :ok = :ssh_connection.send(connection, other, "\e[A\r")
    output = until_prompt(connection, other, "")
    refute output =~ "whoami"
    assert command_count(context) == before

    :ok = :ssh_connection.send(connection, channel, "\r")
    result = until_text(connection, channel, "owner@example.test", "")
    until_prompt(connection, channel, result)
    assert command_count(context) == before + 1
    # A recall followed by transport EOF is not implicit permission to repeat it.
    :ok = :ssh_connection.send(connection, channel, "\e[A")
    :ok = :ssh_connection.send_eof(connection, channel)
    assert collect(connection, channel, %{out: "", err: "", status: nil}).status == 0
    assert command_count(context) == before + 1
  end

  test "PTY wraps, resizes and preserves editable input while a command runs", context do
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :success = :ssh_connection.ptty_alloc(connection, channel, [width: 20], 5000)
    :ok = :ssh_connection.shell(connection, channel)
    until_prompt(connection, channel, "")
    :ok = :ssh_connection.send(connection, channel, "new --request-id queued --json\r")
    wait_for_waiting(connection, channel)
    :ok = :ssh_connection.send(connection, channel, "whoai\e[Dm\eOC --json")
    output = until_text(connection, channel, "porsche> whoami --j\r\nson", "")
    refute output =~ ~r/(?<!\r)\n/
    :ok = :ssh_connection.window_change(connection, channel, 40, 24)
    until_text(connection, channel, "porsche> whoami --json", "")
    :ok = :ssh_connection.window_change(connection, channel, 20, 10)
    until_text(connection, channel, "porsche> whoami --j\r\nson", "")
    :ok = :ssh_connection.window_change(connection, channel, 40, 24)
    until_text(connection, channel, "porsche> whoami --json", "")
    assert command_count(context) == 1
    Agent.update(context.backend, &%{&1 | completed: true})
    output = until_text(connection, channel, "succeeded", "")
    until_text(connection, channel, "porsche> whoami --json", output)
    assert command_count(context) == 1
    :ok = :ssh_connection.send(connection, channel, "\r")
    output = until_text(connection, channel, "owner@example.test", "")
    until_prompt(connection, channel, output)
    assert command_count(context) == 2
  end

  test "submitted input queues during running commands and non-PTY has no redraw", context do
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :ok = :ssh_connection.shell(connection, channel)
    banner = until_prompt(connection, channel, "")
    refute banner =~ "\r"
    :ok = :ssh_connection.send(connection, channel, "new --request-id queue --json\n")
    wait_for_waiting(connection, channel)
    :ok = :ssh_connection.send(connection, channel, "whoai\e[Dm\eOC --json\nexit\n")
    assert command_count(context) == 1
    Agent.update(context.backend, &%{&1 | completed: true})
    result = collect(connection, channel, %{out: "", err: "", status: nil})
    assert result.status == 0
    assert result.out =~ "owner@example.test"
    refute result.out =~ "\e"
    refute result.out =~ "\r"
    refute result.out =~ " _   _ _   _"
    assert command_count(context) == 3
  end

  defp command_count(context),
    do:
      Enum.count(calls(context), fn
        {"commands", %{"command" => %{"command" => name}}} -> name != "request show"
        _ -> false
      end)

  defp until_text(connection, channel, text, output) do
    if String.contains?(output, text) do
      output
    else
      receive do
        {:ssh_cm, ^connection, {:data, ^channel, 0, bytes}} ->
          until_text(connection, channel, text, output <> bytes)
      after
        7000 ->
          flunk("expected SSH output did not arrive: #{inspect(text)} in #{inspect(output)}")
      end
    end
  end

  defp connect(context) do
    {:ok, connection} =
      :ssh.connect(
        ~c"127.0.0.1",
        context.port,
        [
          user: ~c"ignored-account",
          user_dir: String.to_charlist(context.directory),
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

  defp exec(connection, command) do
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :success = :ssh_connection.exec(connection, channel, command, 5000)
    collect(connection, channel, %{out: "", err: "", status: nil})
  end

  defp exec_with_stdin(connection, command, stdin) do
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :success = :ssh_connection.exec(connection, channel, command, 5000)
    :ok = :ssh_connection.send(connection, channel, stdin)
    :ok = :ssh_connection.send_eof(connection, channel)
    collect(connection, channel, %{out: "", err: "", status: nil})
  end

  defp collect(connection, channel, result) do
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
      7000 -> flunk("SSH channel did not close")
    end
  end

  defp until_prompt(connection, channel, output) do
    if String.ends_with?(output, "porsche> ") do
      output
    else
      receive do
        {:ssh_cm, ^connection, {:data, ^channel, 0, bytes}} ->
          until_prompt(connection, channel, output <> bytes)
      after
        7000 -> flunk("SSH prompt did not arrive")
      end
    end
  end

  defp openssh(context, command, extra \\ []) do
    errors = Path.join(context.directory, "stderr-#{System.unique_integer([:positive])}")

    args =
      [
        "-F",
        "/dev/null",
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "IdentityAgent=none",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "ConnectTimeout=5",
        "-p",
        Integer.to_string(context.port),
        "-i",
        Path.join(context.directory, "id_ed25519")
      ] ++
        extra ++
        ["ignored-account@127.0.0.1"] ++ command

    # Static fixture wrapper separates stderr; arguments are never shell text.
    {output, status} =
      System.cmd(
        "sh",
        ["-c", "exec \"$@\" 2>\"$PORSCHE_TEST_STDERR\"", "porsche-test", "ssh" | args],
        env: [{"PORSCHE_TEST_STDERR", errors}]
      )

    {output, File.read!(errors), status}
  end

  defp calls(context), do: Agent.get(context.backend, & &1.calls)

  defp backend_reply("sessions", message, state) do
    {:ok, key} = OverallsProtocol.SSHKey.parse(message["public_key"])
    {:ok, response} = backend_reply("session", %{}, state)
    response = Map.put(response, "session_token", @token)

    if state.approved,
      do: {:ok, response},
      else:
        {:ok,
         Map.merge(response, %{
           "fingerprint" => key.fingerprint,
           "approval_path" =>
             "/ssh/approve/porsche_approval_" <> Base.url_encode64(<<0::256>>, padding: false)
         })}
  end

  defp backend_reply("session", _, state) do
    base = %{"session_id" => @id, "expires_at" => "2099-01-01T00:00:00Z"}

    if state.approved,
      do:
        {:ok,
         Map.merge(base, %{
           "status" => "authenticated",
           "user" => %{"id" => @id, "email" => "owner@example.test"}
         })},
      else: {:ok, Map.put(base, "status", "pending")}
  end

  defp backend_reply("close", _, _), do: {:ok, %{"session_id" => @id, "closed" => true}}

  defp backend_reply("commands", %{"command" => command, "session_token" => @token}, state) do
    case command do
      %{"command" => "whoami"} ->
        {:ok,
         %{
           "version" => 1,
           "status" => "succeeded",
           "result" => %{"id" => @id, "email" => "owner@example.test"}
         }}

      %{"command" => "exit"} ->
        {:ok, %{"version" => 1, "status" => "succeeded", "result" => %{"closed" => true}}}

      %{"command" => "new", "options" => %{"request-id" => id}} ->
        {:ok, receipt(id, "accepted")}

      %{"command" => "integration add"} ->
        {:ok,
         %{
           "version" => 1,
           "request_id" => command["options"]["request-id"],
           "operation_id" => nil,
           "status" => "succeeded",
           "result" => %{"name" => hd(command["arguments"])}
         }}

      %{"command" => "request show", "arguments" => [id]} ->
        {:ok, receipt(id, if(state.completed, do: "succeeded", else: "accepted"))}
    end
  end

  defp receipt(id, status),
    do: %{
      "version" => 1,
      "request_id" => id,
      "operation_id" => @id,
      "status" => status,
      "result" => %{"id" => @id}
    }
end
