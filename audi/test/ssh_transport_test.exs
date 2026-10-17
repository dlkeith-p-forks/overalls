defmodule Audi.SSH.TransportTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  @host "11111111-1111-4111-8111-111111111111"
  @label "vm-11111111111141118111111111111111"

  setup do
    directory = Path.join(System.tmp_dir!(), "audi-ssh-#{System.unique_integer([:positive])}")
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

    parent = self()

    start_supervised!(
      {Task,
       fn ->
         {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
         {:ok, {_, port}} = :inet.sockname(listener)
         send(parent, {:upstream, port})
         {:ok, socket} = :gen_tcp.accept(listener)
         :gen_tcp.close(listener)
         send(parent, :guest_connected)
         echo(socket, parent)
       end}
    )

    assert_receive {:upstream, upstream}

    agent =
      start_supervised!({Agent, fn -> %{allow: true, renew: :allow, host: @host, ttl: 1000} end})

    listener =
      start_supervised!(
        {Audi.SSH.Listener,
         [
           port: 0,
           bind: {127, 0, 0, 1},
           host_key_dir: directory,
           key_cb: {Overalls.TestSSHKeyCallback, [proof: Audi.SSH.Proof]},
           host_id: @host,
           public_origin: "https://control.example.test",
           backend: {Audi.SSHBackendFixture, %{owner: self(), agent: agent, port: upstream}}
         ]}
      )

    port = Audi.SSH.Listener.port(listener)
    public_key = File.read!(Path.join(directory, "ssh_host_ed25519_key.pub"))
    File.write!(Path.join(directory, "known_hosts"), "[127.0.0.1]:#{port} " <> public_key)
    %{directory: directory, port: port, upstream: upstream, agent: agent, listener: listener}
  end

  test "a proved key gets a bidirectional stream and renewals keep it open", context do
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 1000)
    assert :success = :ssh_connection.exec(connection, channel, ~c"connect #{@label}", 2000)
    assert_receive {:authorized, key, @label}
    assert key.algorithm == "ssh-ed25519"
    assert_receive :guest_connected
    payload = :crypto.strong_rand_bytes(32_768)
    assert :ok = :ssh_connection.send(connection, channel, payload, 1000)
    assert receive_bytes(connection, channel, byte_size(payload)) == payload
    assert_receive :renewing, 1500
    assert :ok = :ssh_connection.send(connection, channel, "after renewal", 1000)
    assert receive_bytes(connection, channel, 13) == "after renewal"
    :ssh.close(connection)
    assert_receive :guest_closed, 1000
  end

  # @cc [owner:ghuntley,label:verification;security] ssh-delayed-admission-no-connector
  # A grant delivered after its request-start deadline MUST NOT invoke the
  # connector or forward bytes. Healthy admission MUST still establish a stream.
  property "expired delayed authorization never reaches the guest connector", context do
    supervisor = start_supervised!({Task.Supervisor, []}, id: make_ref())

    check all(ttl <- member_of([25, 75, 150]), max_runs: 4) do
      fence = make_ref()
      Agent.update(context.agent, &Map.merge(&1, %{ttl: ttl, authorization_gate: fence}))
      connection = connect(context)
      {:ok, channel} = :ssh_connection.session_channel(connection, 1000)

      execution =
        Task.Supervisor.async_nolink(supervisor, fn ->
          result = :ssh_connection.exec(connection, channel, ~c"connect #{@label}", 2000)

          closed =
            receive do
              {:ssh_cm, ^connection, {:closed, ^channel}} -> :closed
            after
              2_000 -> :not_closed
            end

          {result, closed}
        end)

      assert_receive {:authorization_waiting, ^fence, worker}, 1000
      observed = System.monotonic_time(:millisecond)
      Process.sleep(ttl + 10)
      assert System.monotonic_time(:millisecond) - observed > ttl
      send(worker, {:release_authorization, fence})
      assert Task.await(execution, 3000) == {:success, :closed}
      refute_receive :connector_called, 50
      refute_receive :guest_connected, 50
      :ssh.close(connection)
    end

    Agent.update(context.agent, &(&1 |> Map.delete(:authorization_gate) |> Map.put(:ttl, 2000)))
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 1000)
    assert :success = :ssh_connection.exec(connection, channel, ~c"connect #{@label}", 2000)
    assert_receive :connector_called, 1000
    assert_receive :guest_connected, 1000
    assert :ok = :ssh_connection.send(connection, channel, "deadline-control", 1000)
    assert receive_bytes(connection, channel, 16) == "deadline-control"
    :ssh.close(connection)
    assert_receive :guest_closed, 1000
  end

  test "denied access and a grant for another host never open a connector", context do
    for change <- [%{allow: false}, %{allow: true, host: "22222222-2222-4222-8222-222222222222"}] do
      Agent.update(context.agent, &Map.merge(&1, change))
      connection = connect(context)
      {:ok, channel} = :ssh_connection.session_channel(connection, 1000)
      assert :success = :ssh_connection.exec(connection, channel, ~c"connect #{@label}", 2000)
      :ssh.close(connection)
    end

    refute_receive :guest_connected
  end

  # @cc [owner:ghuntley,label:verification] audi-ssh-outcome-boundary
  # Denied authority MUST stay outside the denominator; a valid grant with a
  # failed connector MUST count failure, and an acknowledged guest stream MUST
  # count success, with no key or VM identity in the private snapshot.
  test "only valid granted SSH establishment enters the source SLO", context do
    path = Path.join(context.directory, "ssh-slo.json")
    source = start_supervised!({Audi.SLO, path: path, service: "audi_ssh"})

    Agent.update(context.agent, &Map.put(&1, :allow, false))
    denied = connect(context)
    {:ok, denied_channel} = :ssh_connection.session_channel(denied, 1000)
    assert :success = :ssh_connection.exec(denied, denied_channel, ~c"connect #{@label}", 2000)
    :ssh.close(denied)
    assert outcome_count() == 0

    Agent.update(context.agent, &Map.merge(&1, %{allow: true, port: 1}))
    failed = connect(context)
    {:ok, failed_channel} = :ssh_connection.session_channel(failed, 1000)
    assert :success = :ssh_connection.exec(failed, failed_channel, ~c"connect #{@label}", 2000)
    :ssh.close(failed)
    assert wait_outcome_count(1) == 1

    Agent.update(context.agent, &Map.put(&1, :port, context.upstream))
    accepted = connect(context)
    {:ok, accepted_channel} = :ssh_connection.session_channel(accepted, 1000)

    assert :success =
             :ssh_connection.exec(accepted, accepted_channel, ~c"connect #{@label}", 2000)

    assert_receive :guest_connected
    assert wait_outcome_count(2) == 2
    :ssh.close(accepted)

    send(source, :publish)
    :sys.get_state(source)
    assert {:ok, snapshot} = path |> File.read!() |> JSON.decode()
    assert snapshot["requests"] == 2
    assert snapshot["successes"] == 1
    assert snapshot["failures"] == 1
    assert snapshot["duration"]["count"] == 2
    assert Enum.sum(snapshot["duration"]["bucket_counts"]) == 2
    refute inspect(snapshot) =~ @label
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o640
  end

  @spec outcome_count() :: non_neg_integer()
  defp outcome_count do
    [{:slo, requests, _, _, _, _, _, _, _, _, _, _, _, _}] = :ets.lookup(Audi.SLO, :slo)
    requests
  end

  @spec wait_outcome_count(non_neg_integer()) :: non_neg_integer()
  defp wait_outcome_count(expected) do
    Enum.reduce_while(1..50, 0, fn _, _ ->
      count = outcome_count()

      if count == expected do
        {:halt, count}
      else
        Process.sleep(10)
        {:cont, count}
      end
    end)
  end

  for {service, name} <- [{:porsche_ssh, "porsche"}, {:audi_ssh, "audi"}] do
    test "nested #{service} requires signature proof and closes on host-key change", context do
      service = unquote(service)
      name = unquote(name)
      connection = connect(context)
      {:ok, channel} = :ssh_connection.session_channel(connection, 1000)

      assert :success =
               :ssh_connection.exec(connection, channel, "inception #{@label} " <> name, 2000)

      assert_receive {:authorized, key, {:nested, @label, ^service}}
      assert key.algorithm == "ssh-ed25519"
      assert_receive :guest_connected
      assert :ok = :ssh_connection.send(connection, channel, "nested SSH bytes", 1000)
      assert receive_bytes(connection, channel, 16) == "nested SSH bytes"
      assert_receive :renewing, 1500
      Agent.update(context.agent, &Map.put(&1, :host_key, "changed"))
      assert_receive :guest_closed, 2000
      assert_receive {:ssh_cm, ^connection, {:closed, ^channel}}, 1000
      :ssh.close(connection)
    end
  end

  test "a stalled renewal closes the connector and SSH channel", context do
    Agent.update(context.agent, &%{&1 | renew: :hang})
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 1000)
    assert :success = :ssh_connection.exec(connection, channel, ~c"connect #{@label}", 2000)
    assert_receive :renewing, 1500
    assert_receive :guest_closed, 2000
    assert_receive {:ssh_cm, ^connection, {:closed, ^channel}}, 1000
  end

  test "an unsigned public-key probe never reaches authority", context do
    handler = make_ref()

    :ok =
      :telemetry.attach_many(
        handler,
        [[:audi, :ssh, :candidate], [:audi, :ssh, :proved]],
        &__MODULE__.observe/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    public_only = Path.join(context.directory, "probe.pub")
    File.cp!(Path.join(context.directory, "id_ed25519.pub"), public_only)

    {_output, status} =
      System.cmd(
        "ssh",
        [
          "-F",
          "/dev/null",
          "-T",
          "-o",
          "BatchMode=yes",
          "-o",
          "IdentitiesOnly=yes",
          "-o",
          "IdentityAgent=none",
          "-o",
          "ConnectTimeout=2",
          "-o",
          "StrictHostKeyChecking=yes",
          "-o",
          "UserKnownHostsFile=#{Path.join(context.directory, "known_hosts")}",
          "-p",
          Integer.to_string(context.port),
          "-i",
          public_only,
          "ignored-user@127.0.0.1",
          "connect",
          @label
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert_receive {:proof, :candidate, :error}
    refute_receive {:proof, :proved, _}
    refute_receive {:key_status, _}
    refute_receive {:authorized, _, _}
    refute_receive :guest_connected
  end

  def observe(event, _, _, owner),
    do: send(owner, {:proof, List.last(event), Audi.SSH.Proof.lookup(self())})

  test "shell commands and port/address syntax cannot reach authority", context do
    for command <- [
          ~c"uname -a",
          ~c"connect 127.0.0.1:22",
          ~c"connect #{@label} 22",
          ~c"connect #{@label};id"
        ] do
      connection = connect(context)
      {:ok, channel} = :ssh_connection.session_channel(connection, 1000)
      assert :success = :ssh_connection.exec(connection, channel, command, 2000)
      :ssh.close(connection)
    end

    refute_receive {:authorized, _, _}
    refute_receive :guest_connected
  end

  test "PTY and shell only display guidance; subsystems and forwarding remain denied", context do
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 1000)
    assert :success = :ssh_connection.ptty_alloc(connection, channel, [], 1000)
    :ssh.close(connection)
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 1000)
    assert :failure = :ssh_connection.subsystem(connection, channel, ~c"sftp", 1000)

    {:ok, forwarded} =
      :ssh.tcpip_tunnel_to_server(connection, {127, 0, 0, 1}, 0, {127, 0, 0, 1}, context.upstream)

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, forwarded, [:binary, active: false], 1000)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)

    assert {:error, _} =
             :ssh.tcpip_tunnel_from_server(
               connection,
               {127, 0, 0, 1},
               0,
               {127, 0, 0, 1},
               context.upstream
             )

    :ssh.close(connection)
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 1000)
    assert :ok = :ssh_connection.shell(connection, channel)
    assert_receive {:ssh_cm, ^connection, {:closed, ^channel}}, 1000

    refute_receive :guest_connected
  end

  for pty <- [true, false] do
    test "direct diagnostic shell with PTY=#{pty} explains the unknown key", context do
      Agent.update(context.agent, &Map.put(&1, :key_status, {:ok, :unknown}))
      connection = connect(context)
      {:ok, channel} = :ssh_connection.session_channel(connection, 1000)

      if unquote(pty),
        do: assert(:success == :ssh_connection.ptty_alloc(connection, channel, [], 1000))

      assert :ok = :ssh_connection.shell(connection, channel)
      assert_receive {:ssh_cm, ^connection, {:data, ^channel, 1, message}}, 2000
      assert message =~ "We don't recognize this SSH key"
      assert message =~ "ssh control.example.test"
      assert message =~ "without root@"
      if unquote(pty), do: refute(Regex.match?(~r/(?<!\r)\n/, message))
      assert_receive {:ssh_cm, ^connection, {:exit_status, ^channel, 1}}
      refute_receive {:ssh_cm, ^connection, {:data, ^channel, 0, _}}
      refute_receive {:authorized, _, _}
      refute_receive :guest_connected
    end
  end

  test "proxy rejection gives stderr guidance and a nonzero exit without guest bytes", context do
    Agent.update(context.agent, &Map.merge(&1, %{allow: false, key_status: {:ok, :unknown}}))
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 1000)
    assert :success = :ssh_connection.exec(connection, channel, "connect #{@label}", 2000)
    assert_receive {:ssh_cm, ^connection, {:data, ^channel, 1, message}}
    assert message =~ "We don't recognize this SSH key"
    assert_receive {:ssh_cm, ^connection, {:exit_status, ^channel, 1}}
    refute_receive {:ssh_cm, ^connection, {:data, ^channel, 0, _}}
    refute_receive :guest_connected
  end

  test "PTY followed by a valid exec cannot open a connector", context do
    connection = connect(context)
    {:ok, channel} = :ssh_connection.session_channel(connection, 1000)
    assert :success = :ssh_connection.ptty_alloc(connection, channel, [], 1000)
    assert :success = :ssh_connection.exec(connection, channel, "connect #{@label}", 2000)
    assert_receive {:ssh_cm, ^connection, {:data, ^channel, 1, _}}
    refute_receive {:authorized, _, _}
    refute_receive :guest_connected
  end

  test "OpenSSH sees guidance instead of PTY allocation failure", context do
    Agent.update(context.agent, &Map.put(&1, :key_status, {:error, :unavailable}))

    {output, status} =
      System.cmd(
        "ssh",
        [
          "-F",
          "/dev/null",
          "-tt",
          "-o",
          "BatchMode=yes",
          "-o",
          "IdentitiesOnly=yes",
          "-o",
          "IdentityAgent=none",
          "-o",
          "StrictHostKeyChecking=yes",
          "-o",
          "UserKnownHostsFile=#{context.directory}/known_hosts",
          "-i",
          "#{context.directory}/id_ed25519",
          "-p",
          Integer.to_string(context.port),
          "root@127.0.0.1"
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "couldn't verify this SSH key"
    refute output =~ "don't recognize"
    refute output =~ "PTY allocation request failed"
    refute_receive :guest_connected
  end

  test "OpenSSH uses strict host verification and forwards bytes without an Audi client",
       context do
    executable = System.find_executable("ssh")

    args = [
      "-F",
      "/dev/null",
      "-T",
      "-o",
      "BatchMode=yes",
      "-o",
      "IdentitiesOnly=yes",
      "-o",
      "IdentityAgent=none",
      "-o",
      "StrictHostKeyChecking=yes",
      "-o",
      "UserKnownHostsFile=#{Path.join(context.directory, "known_hosts")}",
      "-p",
      Integer.to_string(context.port),
      "-i",
      Path.join(context.directory, "id_ed25519"),
      "ignored-user@127.0.0.1",
      "connect",
      @label
    ]

    port =
      Port.open({:spawn_executable, executable}, [:binary, :exit_status, :use_stdio, args: args])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    assert_receive :guest_connected, 3000
    assert Port.command(port, "SSH-2.0-test-canary\r\n")
    assert_receive {^port, {:data, "SSH-2.0-test-canary\r\n"}}, 1000
    Agent.update(context.agent, &%{&1 | renew: :deny})
    assert_receive {^port, {:exit_status, status}}, 3000
    assert status != 0
    assert_receive :guest_closed, 1000
  end

  for trusted <- [true, false] do
    test "nested OpenSSH verifies both layers and independent inner authority (trusted=#{trusted})",
         context do
      nested_ssh(context, unquote(trusted))
    end
  end

  defp nested_ssh(context, trusted) do
    inner_directory = Path.join(context.directory, "inner")
    File.mkdir_p!(inner_directory)

    for name <- ["ssh_host_ed25519_key", "id_ed25519"] do
      {_, 0} =
        System.cmd("ssh-keygen", [
          "-q",
          "-t",
          "ed25519",
          "-N",
          "",
          "-f",
          Path.join(inner_directory, name)
        ])
    end

    inner_agent =
      start_supervised!(
        {Agent, fn -> %{allow: true, renew: :allow, host: @host, ttl: 2000} end},
        id: :inner_agent
      )

    inner_listener =
      start_supervised!(
        {Audi.SSH.Listener,
         [
           port: 0,
           bind: {127, 0, 0, 1},
           host_key_dir: inner_directory,
           key_cb: {Overalls.TestSSHKeyCallback, [proof: Audi.SSH.Proof]},
           host_id: @host,
           backend:
             {Audi.SSHBackendFixture,
              %{owner: self(), agent: inner_agent, port: context.upstream}}
         ]},
        id: :inner_listener
      )

    {:ok, inner_host_key} =
      OverallsProtocol.SSHKey.parse(
        File.read!(Path.join(inner_directory, "ssh_host_ed25519_key.pub"))
      )

    Agent.update(
      context.agent,
      &Map.merge(&1, %{
        port: Audi.SSH.Listener.port(inner_listener),
        ttl: 2000,
        host_key: inner_host_key.public_key
      })
    )

    known = Path.join(inner_directory, "known_hosts")

    expected =
      if trusted,
        do: inner_host_key.public_key,
        else: File.read!(Path.join(context.directory, "ssh_host_ed25519_key.pub"))

    File.write!(known, "inception-inner " <> String.trim(expected) <> "\n")

    common =
      "-F /dev/null -T -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o ForwardAgent=no -o ClearAllForwardings=yes -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=3"

    proxy =
      "ssh #{common} -o UserKnownHostsFile=#{context.directory}/known_hosts -i #{context.directory}/id_ed25519 -p #{context.port} outer@127.0.0.1 inception #{@label} audi"

    args =
      String.split(common) ++
        [
          "-o",
          "UserKnownHostsFile=#{known}",
          "-o",
          "HostKeyAlias=inception-inner",
          "-o",
          "ProxyCommand=#{proxy}",
          "-i",
          Path.join(inner_directory, "id_ed25519"),
          "inner@127.0.0.1",
          "connect",
          @label
        ]

    port =
      Port.open({:spawn_executable, System.find_executable("ssh")}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: args
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    assert_receive {:authorized, outer_key, {:nested, @label, :audi_ssh}}, 3000

    if trusted do
      assert_receive {:authorized, inner_key, @label}, 3000
      refute inner_key.fingerprint == outer_key.fingerprint
      assert_receive :guest_connected, 3000
      assert Port.command(port, "independent inner SSH")
      assert_receive {^port, {:data, "independent inner SSH"}}, 1000
      Agent.update(inner_agent, &%{&1 | renew: :deny})
      assert_receive :guest_closed, 3000
      assert_receive {^port, {:exit_status, _}}, 3000
    else
      assert_receive {^port, {:exit_status, status}}, 3000
      assert status != 0
      refute_receive {:authorized, _, @label}
      refute_receive :guest_connected
    end
  end

  defp connect(context) do
    {:ok, connection} =
      :ssh.connect(
        ~c"127.0.0.1",
        context.port,
        [
          user: ~c"ignored-user",
          user_dir: String.to_charlist(context.directory),
          user_interaction: false,
          silently_accept_hosts: false,
          auth_methods: ~c"publickey"
        ],
        2000
      )

    on_exit(fn -> :ssh.close(connection) end)
    connection
  end

  defp receive_bytes(connection, channel, remaining, output \\ <<>>)
  defp receive_bytes(_, _, 0, output), do: output

  defp receive_bytes(connection, channel, remaining, output) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, 0, bytes}} ->
        :ssh_connection.adjust_window(connection, channel, byte_size(bytes))
        receive_bytes(connection, channel, remaining - byte_size(bytes), output <> bytes)
    after
      2000 -> flunk("stream data did not arrive")
    end
  end

  defp echo(socket, parent) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, bytes} ->
        :ok = :gen_tcp.send(socket, bytes)
        echo(socket, parent)

      {:error, :closed} ->
        send(parent, :guest_closed)
    end
  end
end
