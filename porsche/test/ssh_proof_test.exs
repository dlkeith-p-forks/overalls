defmodule Porsche.SSH.ProofTest do
  use ExUnit.Case, async: false
  alias Porsche.SSH.Proof

  defmodule InvalidSigner do
    @behaviour :ssh_client_key_api
    @impl true
    def user_key(:"ssh-ed25519", options),
      do:
        {:ok, {:ssh2_pubkey, options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:blob)}}

    def user_key(_, _), do: {:error, ~c"unsupported"}
    @impl true
    def is_host_key(key, _host, _port, _algorithm, options),
      do: key == options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:host_key)

    @impl true
    def sign(_public_key, _data, options) do
      send(
        options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:owner),
        :invalid_signature_sent
      )

      <<0::512>>
    end
  end

  setup context do
    directory = Path.join(System.tmp_dir!(), "porsche-ssh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    # "device" is the P-256 key type Mila keeps in platform key custody.
    for {name, type} <- [
          {"ssh_host_ed25519_key", ["ed25519"]},
          {"user", ["ed25519"]},
          {"device", ["ecdsa", "-b", "256"]}
        ] do
      {_, 0} =
        System.cmd(
          "ssh-keygen",
          ["-q", "-t"] ++ type ++ ["-N", "", "-f", Path.join(directory, name)]
        )
    end

    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [[:porsche, :ssh, :candidate], [:porsche, :ssh, :proved]],
        &__MODULE__.observe/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, client} =
      Porsche.Client.new(
        "https://marshall.test",
        "porsche_gateway_" <> Base.url_encode64(<<0::256>>, padding: false)
      )

    connected = fn user, peer, method ->
      Proof.authenticated(user, peer, method)

      if context[:connection_actor] do
        request = &__MODULE__.backend(&1, &2, &3, parent)
        {:ok, actor} = Porsche.Connection.open(self(), client, request: request)
        snapshots = Enum.map(1..3, fn _ -> Porsche.Connection.snapshot(self()) end)
        send(parent, {:connection_actor, actor, snapshots})
      end
    end

    {:ok, daemon} =
      :ssh.daemon({127, 0, 0, 1}, 0,
        system_dir: String.to_charlist(directory),
        auth_methods: ~c"publickey",
        key_cb: {Overalls.TestSSHKeyCallback, [proof: Proof]},
        connectfun: connected,
        ssh_cli: :no_cli,
        shell: :disabled,
        exec: :disabled,
        subsystems: [],
        tcpip_tunnel_in: false,
        tcpip_tunnel_out: false
      )

    {:ok, info} = :ssh.daemon_info(daemon)
    port = Keyword.fetch!(info, :port)
    on_exit(fn -> :ssh.stop_daemon(daemon) end)

    {:ok, key} =
      directory |> Path.join("user.pub") |> File.read!() |> OverallsProtocol.SSHKey.parse()

    %{directory: directory, port: port, key: key}
  end

  # Telemetry runs in the connection process; inspect proof at that exact point
  # so a quick client disconnect cannot conceal whether it ever existed.
  def observe(event, %{count: 1}, %{}, owner),
    do: send(owner, {:proof_event, List.last(event), self(), Proof.lookup(self())})

  test "OpenSSH unsigned probes never establish possession", context do
    public_only = Path.join(context.directory, "probe.pub")
    File.cp!(Path.join(context.directory, "user.pub"), public_only)
    {_output, status} = ssh(context, public_only)
    assert status != 0
    assert_receive {:proof_event, :candidate, connection, :error}
    refute_receive {:proof_event, :proved, _, _}
    assert :error = Proof.lookup(connection)
  end

  test "OpenSSH signed authentication binds the key, ignores the username, and cleans up",
       context do
    {_output, _status} = ssh(context, Path.join(context.directory, "user"))
    assert_receive {:proof_event, :candidate, connection, :error}
    assert_receive {:proof_event, :proved, ^connection, {:ok, key}}
    assert key == context.key
    monitor = Process.monitor(connection)
    assert_receive {:DOWN, ^monitor, :process, ^connection, _}
    eventually_absent(connection)
  end

  test "a signed P-256 device key proves possession like any other client key", context do
    {:ok, device} =
      context.directory
      |> Path.join("device.pub")
      |> File.read!()
      |> OverallsProtocol.SSHKey.parse()

    assert device.algorithm == "ecdsa-sha2-nistp256"
    {_output, _status} = ssh(context, Path.join(context.directory, "device"))
    assert_receive {:proof_event, :candidate, connection, :error}
    assert_receive {:proof_event, :proved, ^connection, {:ok, ^device}}
  end

  test "a callback without a candidate fails closed" do
    assert_raise RuntimeError, "SSH signature has no candidate key", fn ->
      Proof.authenticated(~c"untrusted-owner", {{127, 0, 0, 1}, 22}, ~c"publickey")
    end

    assert :error = Proof.lookup(self())

    assert_raise RuntimeError, "SSH requires public-key authentication", fn ->
      Proof.authenticated(~c"untrusted-owner", nil, ~c"password")
    end
  end

  @tag connection_actor: true
  test "the connection actor opens only after proof, observes approval, and closes on disconnect",
       context do
    {_output, _status} = ssh(context, Path.join(context.directory, "user"))
    assert_receive {:proof_event, :proved, connection, {:ok, _}}
    assert_receive {:backend, "sessions", %{"public_key" => public_key, "version" => 1}}
    assert public_key == context.key.public_key
    assert_receive {:connection_actor, actor, [{:ok, pending}, {:ok, approved}, {:ok, cached}]}
    assert pending["status"] == "pending"
    assert approved["status"] == "authenticated"
    assert Porsche.Locale.from_session(approved) == "ja"
    refute Map.has_key?(approved, "approval_path")
    assert cached == approved
    assert_receive {:backend, "session", %{"session_token" => token}}
    assert_receive {:backend, "session", %{"session_token" => ^token}}
    assert_receive {:backend, "close", %{"session_token" => ^token}}
    refute_receive {:backend, "sessions", _}
    refute_receive {:backend, "session", _}
    monitor = Process.monitor(actor)
    assert_receive {:DOWN, ^monitor, :process, ^actor, _}
    assert {:error, :unauthorized} = Porsche.Connection.snapshot(connection)
  end

  @tag connection_actor: true
  test "an unsigned probe cannot reach the Marshall session API", context do
    public_only = Path.join(context.directory, "only-public.pub")
    File.cp!(Path.join(context.directory, "user.pub"), public_only)
    {_output, status} = ssh(context, public_only)
    assert status != 0
    assert_receive {:proof_event, :candidate, _, :error}
    refute_receive {:backend, _, _}
    refute_receive {:connection_actor, _, _}
  end

  test "unproven processes cannot start connection actors" do
    {:ok, client} =
      Porsche.Client.new(
        "https://marshall.test",
        "porsche_gateway_" <> Base.url_encode64(<<0::256>>, padding: false)
      )

    assert {:error, :unproven_connection} = Porsche.Connection.open(self(), client)
  end

  @tag connection_actor: true
  test "a real SSH authentication attempt with an invalid signature cannot open a session",
       context do
    [_, encoded] = String.split(context.key.public_key)

    [{host_key, _}] =
      context.directory
      |> Path.join("ssh_host_ed25519_key.pub")
      |> File.read!()
      |> :ssh_file.decode(:openssh_key)

    assert {:error, _} =
             :ssh.connect(
               ~c"127.0.0.1",
               context.port,
               [
                 user: ~c"untrusted-account-name",
                 auth_methods: ~c"publickey",
                 pref_public_key_algs: [:"ssh-ed25519"],
                 user_interaction: false,
                 key_cb:
                   {InvalidSigner,
                    [blob: Base.decode64!(encoded), host_key: host_key, owner: self()]}
               ],
               5000
             )

    assert_receive :invalid_signature_sent
    assert_receive {:proof_event, :candidate, connection, :error}
    refute_receive {:proof_event, :proved, _, _}
    refute_receive {:backend, _, _}
    assert :error = Proof.lookup(connection)
  end

  # Scripted Marshall replies isolate the SSH proof/actor boundary. They are not
  # evidence of real Ash authorization or the production HTTPS integration.
  def backend(_client, route, message, owner) do
    send(owner, {:backend, route, message})
    id = "11111111-1111-4111-8111-111111111111"
    base = %{"session_id" => id, "expires_at" => "2099-01-01T00:00:00Z"}
    random = Base.url_encode64(<<0::256>>, padding: false)

    case route do
      "sessions" ->
        {:ok, key} = OverallsProtocol.SSHKey.parse(message["public_key"])

        {:ok,
         Map.merge(base, %{
           "status" => "pending",
           "session_token" => "porsche_session_" <> random,
           "fingerprint" => key.fingerprint,
           "approval_path" => "/ssh/approve/porsche_approval_" <> random
         })}

      "session" ->
        count = Process.get({__MODULE__, :polls}, 0)
        Process.put({__MODULE__, :polls}, count + 1)

        if count == 0 do
          {:ok, Map.put(base, "status", "pending")}
        else
          {:ok,
           Map.merge(base, %{
             "status" => "authenticated",
             "user" => %{"id" => id, "email" => "owner@example.test", "locale" => "ja"}
           })}
        end

      "close" ->
        {:ok, %{"session_id" => id, "closed" => true}}
    end
  end

  defp ssh(context, key) do
    System.cmd(
      "ssh",
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
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        "ConnectTimeout=5",
        "-o",
        "PreferredAuthentications=publickey",
        "-p",
        Integer.to_string(context.port),
        "-i",
        key,
        "untrusted-account-name@127.0.0.1",
        "help"
      ],
      stderr_to_stdout: true
    )
  end

  defp eventually_absent(connection, attempts \\ 100)
  defp eventually_absent(connection, 0), do: assert(:error == Proof.lookup(connection))

  defp eventually_absent(connection, attempts) do
    case Proof.lookup(connection) do
      :error ->
        :ok

      _ ->
        Process.sleep(5)
        eventually_absent(connection, attempts - 1)
    end
  end
end
