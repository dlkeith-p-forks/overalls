defmodule MarshallWeb.SSHTransportTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.{Compute, SSH}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes, Reservation, VirtualMachine}
  @certificate Path.expand("../fixtures/tls/localhost.pem", __DIR__)
  @key Path.expand("../fixtures/tls/localhost.key", __DIR__)
  @ca Path.expand("../fixtures/tls/ca.pem", __DIR__)

  defmodule ControlThenSSH do
    @moduledoc false
    @behaviour Plug
    def init(options), do: options

    def call(conn, _options) do
      conn = MarshallWeb.ControlAPI.call(conn, [])
      if conn.halted, do: conn, else: MarshallWeb.SSHAPI.call(conn, [])
    end
  end

  # Kills the control connection instead of sending the first committed
  # commands reply: the request is unproven to Porsche, as a lost reply.
  defmodule DropReply do
    @moduledoc false
    @behaviour Plug
    def init(options), do: options

    def call(conn, {flag, owner}),
      do:
        MarshallWeb.ControlAPI.call(conn,
          socket: __MODULE__.Socket,
          socket_state: %{drop: {flag, owner}}
        )

    defmodule Socket do
      @moduledoc false
      @behaviour WebSock
      alias OverallsProtocol.Control.Envelope
      alias Marshall.Control.Socket, as: Inner

      @impl true
      def init(state) do
        {:ok, inner} = Inner.init(Map.delete(state, :drop))
        {:ok, %{inner: inner, drop: state.drop, commands: MapSet.new()}}
      end

      @impl true
      def handle_in({text, _options} = frame, state) do
        commands =
          case Envelope.decode(text) do
            {:ok, {:req, %{id: id, op: "porsche.commands"}}} -> MapSet.put(state.commands, id)
            _ -> state.commands
          end

        wrap(Inner.handle_in(frame, state.inner), %{state | commands: commands})
      end

      @impl true
      def handle_info(message, state), do: wrap(Inner.handle_info(message, state.inner), state)

      @impl true
      def terminate(reason, state), do: Inner.terminate(reason, state.inner)

      defp wrap({:push, {:text, text}, inner} = result, state) do
        {flag, owner} = state.drop

        with {:ok, {:res, %{id: id, result: {:ok, _}}}} <- Envelope.decode(text),
             true <- MapSet.member?(state.commands, id),
             true <- Agent.get_and_update(flag, &{&1, false}) do
          send(owner, :committed_reply_dropped)
          Process.exit(self(), :kill)
        end

        put_elem(result, 2, %{state | inner: inner})
      end

      defp wrap(result, state) when is_tuple(result) do
        last = tuple_size(result) - 1
        put_elem(result, last, %{state | inner: elem(result, last)})
      end
    end
  end

  setup context do
    fixture = host_fixture()
    owner = user()

    directory =
      Path.join(System.tmp_dir!(), "marshall-porsche-#{System.unique_integer([:positive])}")

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

    key =
      unless context[:pending],
        do: SSH.add_key(%{public_key: public_key}, actor: owner) |> elem(1)

    {gateway, _} = SSH.Token.issue(:gateway)

    {:ok, gateway_identity} =
      SSH.configure_gateway(%{name: "native-transport", token: gateway},
        actor: SystemActor.compute()
      )

    {:ok, _} = Application.ensure_all_started(:ssh)
    start_supervised!({Registry, keys: :unique, name: Porsche.SSH.Proofs})
    start_supervised!({Registry, keys: :unique, name: Porsche.SSH.Sessions})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: Porsche.SSH.Connections})
    start_supervised!({Task.Supervisor, name: Porsche.SSH.Commands})
    start_supervised!(Porsche.Watchers)
    on_exit(fn -> :logger.remove_primary_filter(:porsche_privacy) end)

    plug =
      if context[:drop_reply] do
        flag = start_supervised!({Agent, fn -> true end})
        {DropReply, {flag, self()}}
      else
        ControlThenSSH
      end

    server =
      start_supervised!(
        {Bandit,
         [
           plug: plug,
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
    options = Keyword.put(options, :client, client)

    listener =
      start_supervised!(
        {Porsche.Listener,
         Keyword.put(options, :key_cb, {Overalls.TestSSHKeyCallback, [proof: Porsche.SSH.Proof]})}
      )

    previous = Application.fetch_env(:marshall, :default_image_id)
    Application.put_env(:marshall, :default_image_id, image_id())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:marshall, :default_image_id, value)
        :error -> Application.delete_env(:marshall, :default_image_id)
      end
    end)

    Map.merge(fixture, %{
      directory: directory,
      port: Porsche.Listener.port(listener),
      owner: owner,
      public_key: public_key,
      key: key,
      gateway: gateway,
      gateway_id: gateway_identity.id,
      origin: origin,
      control: client.control
    })
  end

  test "private readiness socket observes real HTTPS gateway revocation", c do
    {:ok, client} = Porsche.Client.new(c.origin, c.gateway, cacertfile: @ca)
    client = control(client)
    path = Path.join(c.directory, "status.sock")
    start_supervised!({Porsche.StatusServer, [path: path, client: client]})

    read = fn ->
      {:ok, socket} =
        :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line], 1000)

      {:ok, bytes} = :gen_tcp.recv(socket, 0, 8000)
      :gen_tcp.close(socket)
      Jason.decode!(bytes)
    end

    assert read.() == %{"version" => 1, "ready" => true}
    assert Ledger.read!(SSH.Session) == []
    {:ok, _} = SSH.disable_gateway(%{id: c.gateway_id}, actor: SystemActor.compute())
    assert read.() == %{"version" => 1, "ready" => false}
    assert Ledger.read!(SSH.Session) == []
  end

  test "real SSH and verified HTTPS dispatch through Ash with durable jobs and sharing", c do
    connection = connect(c)
    assert exec(connection, "whoami --json").response["result"]["id"] == c.owner.id

    created =
      exec(
        connection,
        "new --profile standard --name native-machine --request-id native-create --no-wait --json"
      )

    assert created.status == 0
    assert created.response["status"] == "accepted"
    assert length(Ledger.read!(VirtualMachine)) == 1
    assert length(Ledger.read!(Reservation)) == 1
    assert length(Ledger.read!(SSH.Request)) == 1

    assert length(
             Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: Compute.Workers.Dispatch)
           ) == 1

    assert exec(connection, "show native-machine --json").response["result"]["name"] ==
             "native-machine"

    other = user()

    shared =
      exec(
        connection,
        "share add native-machine #{other.email} viewer --request-id native-share --json"
      )

    assert shared.status == 0
    assert {:ok, _} = Compute.resolve_vm(%{reference: "native-machine"}, actor: other)

    assert exec(
             connection,
             "share remove native-machine #{other.email} --request-id native-unshare --json"
           ).status == 0

    assert {:error, _} = Compute.resolve_vm(%{reference: "native-machine"}, actor: other)
  end

  test "revocation fences existing channels while accepted work replays across key rotation",
       c do
    connection = connect(c)
    accepted = exec(connection, "new --request-id revoked-work --no-wait --json").response
    assert {:ok, _} = SSH.remove_key(%{id: c.key.id}, actor: c.owner)
    assert exec(connection, "request show revoked-work --json").status == 3
    assert length(Ledger.read!(Operation)) == 1

    assert length(
             Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: Compute.Workers.Dispatch)
           ) == 1

    assert {:ok, new_key} = SSH.add_key(%{public_key: c.public_key}, actor: c.owner)
    refute new_key.id == c.key.id
    assert exec(connection, "whoami --json").status == 3
    fresh = connect(c)
    assert exec(fresh, "request show revoked-work --json").response == accepted
    replay = exec(fresh, "new --request-id revoked-work --no-wait --json")
    assert replay.status == 0
    assert replay.response == accepted
    assert length(Ledger.read!(VirtualMachine)) == 1
  end

  @tag pending: true
  test "browser-domain approval promotes the same SSH connection without admitting its earlier exec",
       c do
    connection = connect(c)
    pending = exec(connection, "new --no-wait --json")
    assert pending.status == 3
    assert pending.response["status"] == "approval_required"
    assert Ledger.read!(VirtualMachine) == []
    assert Ledger.read!(SSH.Request) == []

    token =
      pending.response["approval_url"] |> URI.parse() |> Map.fetch!(:path) |> Path.basename()

    assert {:ok, _} = SSH.approve_key(%{token: token}, actor: c.owner)
    assert exec(connection, "whoami --json").response["result"]["id"] == c.owner.id
    assert exec(connection, "new --request-id approved-create --no-wait --json").status == 0
    assert length(Ledger.read!(SSH.Session)) == 1
  end

  @tag drop_reply: true
  test "a dropped committed HTTPS response is recovered by the same request ID exactly once", c do
    connection = connect(c)
    lost = exec(connection, "new --name lost-reply --request-id stable-retry --no-wait --json")
    assert_receive :committed_reply_dropped
    assert lost.status != 0
    assert lost.response["request_id"] == "stable-retry"
    # The lost reply dropped the control socket; retry once it is back.
    Enum.reduce_while(1..250, :ok, fn _, :ok ->
      if OverallsProtocol.Control.Client.ready?(c.control),
        do: {:halt, :ok},
        else: (Process.sleep(20) && {:cont, :ok}) || {:cont, :ok}
    end)

    assert [receipt] = Ledger.read!(SSH.Request)
    assert receipt.status == :accepted
    retry = exec(connection, "new --name lost-reply --request-id stable-retry --no-wait --json")
    assert retry.status == 0
    assert retry.response["operation_id"] == receipt.operation_id
    assert length(Ledger.read!(VirtualMachine)) == 1
    assert length(Ledger.read!(Reservation)) == 1
    assert length(Ledger.read!(Operation)) == 1
    assert length(Ledger.read!(SSH.Request)) == 1

    assert length(
             Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: Compute.Workers.Dispatch)
           ) == 1
  end

  test "physical waits ignore acknowledgement and complete only after matching outcome evidence",
       c do
    connection = connect(c)
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)

    :success =
      :ssh_connection.exec(
        connection,
        channel,
        "new --request-id wait-native --timeout 10 --json",
        5000
      )

    wait_for_waiting(connection, channel)
    [operation] = Ledger.read!(Operation)
    Ledger.update!(operation, :acknowledge, %{})
    wait_for_waiting(connection, channel)
    refute_receive {:ssh_cm, ^connection, {:data, ^channel, 0, _}}, 50

    event = %{
      id: Ash.UUID.generate(),
      vm_id: operation.vm_id,
      operation_id: operation.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      generation: operation.generation,
      sequence: 1,
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    assert {:ok, _} =
             Ledger.transaction(fn ->
               Ledger.lock!(Host, c.host.id)
               Outcomes.ingest_locked!(c.host.id, [event])
             end)

    result = collect(connection, channel, %{out: "", err: "", status: nil})
    assert result.status == 0
    assert result.response["status"] == "succeeded"
    assert result.response["operation_id"] == operation.id
  end

  test "gateway revocation blocks new sessions and a wrong TLS authority cannot open one", c do
    {:ok, bad_ca} = Porsche.Client.new(c.origin, c.gateway)
    bad_ca = control(bad_ca)

    assert {:error, :transport_error} =
             Porsche.Client.request(bad_ca, "sessions", %{
               "version" => 1,
               "public_key" => c.public_key
             })

    assert Ledger.read!(SSH.Session) == []

    assert {:ok, _} =
             SSH.disable_gateway(%{id: c.gateway_id}, actor: SystemActor.compute())

    connection = connect(c)
    assert exec(connection, "whoami --json").status == 3
    assert Ledger.read!(SSH.Session) == []
  end

  # @cc [owner:ghuntley,label:verification;security] porsche-threads-transport
  # Over real SSH, Porsche and verified HTTPS control, a prompt MUST travel only
  # as a stdin payload into the Threads domain, thread reads MUST reflect it,
  # and a watch MUST open through Marshall's subscription authority, renew on
  # heartbeat and end with exit 3 once the key is revoked. Committed-hint
  # delivery is outside this sandboxed test (pg_notify needs a commit).
  test "porsche-threads: stdin prompts, thread reads and a revocable watch", c do
    previous = Application.get_env(:porsche, :watch_heartbeat_ms)
    Application.put_env(:porsche, :watch_heartbeat_ms, 300)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:porsche, :watch_heartbeat_ms, previous),
        else: Application.delete_env(:porsche, :watch_heartbeat_ms)
    end)

    thread = ready_thread(c.owner)
    connection = connect(c)
    prompt = "Run the test suite and summarise failures.\n"

    prompted =
      exec_with_stdin(
        connection,
        "thread prompt #{thread.id} - --request-id transport-prompt --json",
        prompt
      )

    assert prompted.status == 0
    assert prompted.response["status"] == "succeeded"
    refute prompted.out =~ "summarise failures"
    [turn] = Ledger.read!(Marshall.Agents.Turn, id: prompted.response["result"]["turn_id"])
    assert turn.prompt == String.trim(prompt)
    [request] = Ledger.read!(SSH.Request, request_id: "transport-prompt")
    assert request.ssh_key_id == c.key.id
    refute JSON.encode!(request.command) =~ "summarise failures"

    listed = exec(connection, "thread ls --json").response["result"]["items"]
    assert Enum.map(listed, & &1["id"]) == [thread.id]
    assert exec(connection, "thread show #{thread.id} --json").response["result"]["busy"]

    assert exec(connection, "thread read #{thread.id} 1 --request-id transport-read --json").status ==
             0

    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :success = :ssh_connection.exec(connection, channel, "watch --thread #{thread.id}", 5000)
    opened = until_text(connection, channel, "\"heartbeat\"", "")
    [watching | _] = opened |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    assert watching["event"] == "watching"
    assert watching["threads"] == [thread.id]

    assert {:ok, _} = SSH.remove_key(%{id: c.key.id}, actor: c.owner)
    closed = collect_raw(connection, channel, %{out: "", err: "", status: nil})
    assert closed.status == 3
  end

  defp ready_thread(owner) do
    request = request()

    {:ok, thread} =
      Marshall.Threads.create_thread(
        %{
          objective: "Improve the workspace",
          mode: :medium,
          machine_spec: request,
          idempotency_key: request.idempotency_key
        },
        actor: owner
      )

    args = %{"thread_id" => thread.id, "machine_key" => thread.machine_key}
    {:snooze, _} = Marshall.Threads.ProvisionWorker.perform(%Oban.Job{args: args})
    [vm] = Ledger.read!(VirtualMachine, idempotency_key: thread.machine_key)
    Ledger.update!(vm, :observe, %{observed_state: :running})
    :ok = Marshall.Threads.ProvisionWorker.perform(%Oban.Job{args: args})
    [ready] = Ledger.read!(Marshall.Threads.Thread, id: thread.id)

    for turn <- Ledger.read!(Marshall.Agents.Turn, thread_id: ready.agent_thread_id),
        turn.status in [:queued, :running],
        do: Ledger.update!(turn, :transition, %{status: :completed, finished_at: Ledger.now()})

    ready
  end

  defp exec_with_stdin(connection, command, stdin) do
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :success = :ssh_connection.exec(connection, channel, command, 5000)
    :ok = :ssh_connection.send(connection, channel, stdin)
    :ok = :ssh_connection.send_eof(connection, channel)
    collect(connection, channel, %{out: "", err: "", status: nil})
  end

  defp until_text(connection, channel, text, output) do
    if String.contains?(output, text) do
      output
    else
      receive do
        {:ssh_cm, ^connection, {:data, ^channel, 0, bytes}} ->
          :ssh_connection.adjust_window(connection, channel, byte_size(bytes))
          until_text(connection, channel, text, output <> bytes)
      after
        8000 -> flunk("expected SSH output did not arrive: #{inspect(text)}")
      end
    end
  end

  defp collect_raw(connection, channel, result) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, stream, bytes}} ->
        :ssh_connection.adjust_window(connection, channel, byte_size(bytes))
        key = if stream == 0, do: :out, else: :err
        collect_raw(connection, channel, Map.update!(result, key, &(&1 <> bytes)))

      {:ssh_cm, ^connection, {:exit_status, ^channel, status}} ->
        collect_raw(connection, channel, %{result | status: status})

      {:ssh_cm, ^connection, {:eof, ^channel}} ->
        collect_raw(connection, channel, result)

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        result
    after
      12_000 -> flunk("SSH channel did not close")
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
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

  defp exec(connection, command) do
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :success = :ssh_connection.exec(connection, channel, command, 5000)
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
        Map.put(result, :response, JSON.decode!(result.out))
    after
      12_000 -> flunk("SSH command did not finish")
    end
  end

  defp wait_for_waiting(connection, channel) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, 1, bytes}} ->
        if not String.contains?(bytes, "waiting for completion"),
          do: wait_for_waiting(connection, channel)
    after
      5000 -> flunk("SSH command did not wait for completion")
    end
  end

  # Starts the client's control link under the test supervisor and waits
  # briefly for its welcome; a link that cannot connect is left for the test.
  @spec control(Porsche.Client.t()) :: Porsche.Client.t()
  defp control(client) do
    client = %{client | control: :"porsche_transport_#{System.unique_integer([:positive])}"}
    start_supervised!({Porsche.Control.Link, client}, id: client.control)

    Enum.reduce_while(1..50, :ok, fn _, :ok ->
      if OverallsProtocol.Control.Client.ready?(client.control),
        do: {:halt, :ok},
        else: (Process.sleep(20) && {:cont, :ok}) || {:cont, :ok}
    end)

    client
  end
end
