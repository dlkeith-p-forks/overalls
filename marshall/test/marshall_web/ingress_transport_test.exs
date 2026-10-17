defmodule MarshallWeb.IngressTransportTest do
  use Marshall.DataCase, async: false
  alias Audi.Control.Client
  alias Marshall.Authorization.SystemActor
  alias Marshall.Ingress
  alias Marshall.IngressReplyFixture, as: Reply
  @certificate Path.expand("../fixtures/tls/localhost.pem", __DIR__)
  @key Path.expand("../fixtures/tls/localhost.key", __DIR__)
  @ca Path.expand("../fixtures/tls/ca.pem", __DIR__)

  setup do
    {token, _} = Ingress.Token.issue()

    {:ok, service} =
      Ingress.configure_service(%{name: "transport", role: :dns, token: token},
        actor: SystemActor.compute()
      )

    %{token: token, service: service}
  end

  test "Audi verifies TLS and current credentials against the actual control API", c do
    url = listener(MarshallWeb.ControlAPI)
    {:ok, client} = client(url, c.token, :dns, cacertfile: @ca)
    assert {:ok, %{id: id, role: :dns, generation: 1}} = Client.identity(client)
    assert id == c.service.id
    {:ok, _} = Ingress.disable_service(%{id: id}, actor: SystemActor.compute())
    assert {:error, :unauthorized} = Client.identity(client)
    refute inspect(client) =~ c.token
  end

  test "untrusted certificates and wrong local role fail closed", c do
    url = listener(MarshallWeb.ControlAPI)
    {:ok, untrusted} = client(url, c.token, :dns)

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :transport_error} = Client.identity(untrusted)
      end)

    refute logs =~ c.token

    {:ok, wrong_role} =
      client(url, c.token, :gateway, cacertfile: @ca, host_id: Ash.UUID.generate())

    # The control socket refuses a hello whose role or host differs from the
    # credential's, so no request is ever answered; the refusal stays a
    # permanent unauthorized class, not a transport outage.
    assert eventually(fn -> Client.identity(wrong_role) == {:error, :transport_error} end)
  end

  test "a trusted certificate still requires the correct server hostname", c do
    url = listener(MarshallWeb.ControlAPI, {127, 0, 0, 2})
    {:ok, client} = client(url, c.token, :dns, cacertfile: @ca)
    assert {:error, :transport_error} = Client.identity(client)
  end

  test "the real Audi client opens, renews and closes durable SSH authority over TLS" do
    c = ssh_fixture()
    assert {:ok, grant} = Client.open_ssh(c.client, c.public_key, c.label)
    assert grant.binding.vm_id == c.vm.id
    assert grant.binding.host_id == c.vm.host_id
    assert grant.binding.generation == c.vm.generation
    assert {:ok, renewed} = Client.renew_ssh(c.client, grant.ticket, grant.binding)
    assert renewed.binding == grant.binding
    assert {:ok, %{closed: true}} = Client.close_ssh(c.client, grant.ticket)
    assert {:error, :unauthorized} = Client.renew_ssh(c.client, grant.ticket, grant.binding)
  end

  test "key recognition is fresh over verified HTTPS and grants no session" do
    c = ssh_fixture()
    assert {:ok, :recognized} = Client.ssh_key_status(c.client, c.public_key)
    assert [] == Marshall.Compute.Ledger.read!(Ingress.Session)
    assert {:ok, _} = Marshall.SSH.remove_key(%{id: c.key.id}, actor: c.owner)
    assert {:ok, :unknown} = Client.ssh_key_status(c.client, c.public_key)
    assert [] == Marshall.Compute.Ledger.read!(Ingress.Session)
  end

  test "old servers and malformed key-status replies never report unknown", c do
    public = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 8::256>>)

    for {status, body} <- [
          {404, "not found"},
          {200, "not json"},
          {200, Jason.encode!(%{version: 2, result: %{status: "unknown"}})},
          {200, Jason.encode!(%{version: 1, result: %{status: "unknown", user: "secret"}})}
        ] do
      url = listener({Reply, {self(), status, body, []}})

      {:ok, client} =
        client(url, c.token, :gateway, host_id: Ash.UUID.generate(), cacertfile: @ca)

      assert {:error, _} = Client.ssh_key_status(client, public)
    end
  end

  test "host-key publication uses the actual authenticated TLS API and immutable generation" do
    c = ssh_fixture()
    assert {:ok, registered} = Client.publish_host_key(c.client, c.public_key)
    assert registered.host_id == c.vm.host_id
    assert registered.public_key == c.public_key
    assert {:ok, ^registered} = Client.publish_host_key(c.client, c.public_key)
    different = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 43::256>>)
    assert {:error, :http_error} = Client.publish_host_key(c.client, different)
    assert {:ok, ^registered} = Client.publish_host_key(c.client, c.public_key)
  end

  test "host-key acknowledgements cannot change the key or configured host", c do
    host = Ash.UUID.generate()
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 41::256>>)
    registered = %{service_id: Ash.UUID.generate(), host_id: host, generation: 1, public_key: key}

    for changed <- [
          Map.put(registered, :host_id, Ash.UUID.generate()),
          Map.put(registered, :public_key, "replacement"),
          Map.put(registered, :generation, 0),
          Map.put(registered, :extra, true)
        ] do
      url = listener({Reply, {self(), 200, Jason.encode!(%{version: 1, host_key: changed}), []}})
      {:ok, client} = client(url, c.token, :gateway, host_id: host, cacertfile: @ca)
      assert {:error, :binding_mismatch} = Client.publish_host_key(client, key)
    end
  end

  test "key revocation crosses the real HTTPS boundary without exposing credentials" do
    c = ssh_fixture()
    {:ok, grant} = Client.open_ssh(c.client, c.public_key, c.label)
    {:ok, _} = Marshall.SSH.remove_key(%{id: c.key.id}, actor: c.owner)

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :unauthorized} = Client.renew_ssh(c.client, grant.ticket, grant.binding)
        assert {:error, :unauthorized} = Client.open_ssh(c.client, c.public_key, c.label)
      end)

    refute logs =~ c.client.token
    refute logs =~ grant.ticket
  end

  test "renewal refuses a changed or extended response binding", c do
    host = Ash.UUID.generate()

    binding = %{
      host_id: host,
      vm_id: Ash.UUID.generate(),
      placement_id: Ash.UUID.generate(),
      session_id: Ash.UUID.generate(),
      execution_epoch: 1,
      generation: 1,
      label: "vm-11111111111141118111111111111111",
      service: :ssh,
      port: 22
    }

    {ticket, _} = Ingress.Token.issue(:session)

    for changed <- [%{binding | generation: 2}, Map.put(binding, :extra, "ignored")] do
      body = JSON.encode!(%{version: 1, grant: %{binding: changed, ttl: 5000}})
      url = listener({Reply, {self(), 200, body, []}})
      {:ok, client} = client(url, c.token, :gateway, host_id: host, cacertfile: @ca)
      assert {:error, reason} = Client.renew_ssh(client, ticket, binding)
      assert reason in [:binding_mismatch, :invalid_message]
    end
  end

  test "a live Audi SSH stream closes after Marshall revokes its proved key" do
    {:ok, _} = Application.ensure_all_started(:ssh)
    c = ssh_fixture()

    directory =
      Path.join(System.tmp_dir!(), "audi-authority-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    for name <- ["id_ed25519", "ssh_host_ed25519_key"] do
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

    publisher =
      start_supervised!({Audi.SSH.KeyPublisher, client: c.client, host_key_dir: directory})

    :sys.get_state(publisher)
    {:ok, host_key} = Audi.SSH.HostKey.public(directory)

    assert [%{ssh_host_key: ^host_key}] =
             Marshall.Compute.Ledger.read!(Ingress.Service, host_id: c.vm.host_id)

    {:ok, key} =
      Marshall.SSH.add_key(%{public_key: File.read!(Path.join(directory, "id_ed25519.pub"))},
        actor: c.owner
      )

    unless Process.whereis(Audi.SSH.Proofs),
      do: start_supervised!({Registry, keys: :unique, name: Audi.SSH.Proofs})

    unless Process.whereis(Audi.Control.Hints),
      do: start_supervised!({Registry, keys: :duplicate, name: Audi.Control.Hints})

    existing_filter = Keyword.has_key?(:logger.get_primary_config().filters, :audi_privacy)
    on_exit(fn -> unless existing_filter, do: :logger.remove_primary_filter(:audi_privacy) end)

    owner = self()

    start_supervised!(
      {Task,
       fn ->
         {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
         {:ok, {_, port}} = :inet.sockname(listener)
         send(owner, {:connector_port, port})
         {:ok, socket} = :gen_tcp.accept(listener)
         :gen_tcp.close(listener)
         {:ok, bytes} = :gen_tcp.recv(socket, 0, 3000)
         :ok = :gen_tcp.send(socket, bytes)
         {:error, :closed} = :gen_tcp.recv(socket, 0, 6000)
         send(owner, :connector_closed)
       end}
    )

    assert_receive {:connector_port, connector_port}

    connector_path = Path.join(directory, "lilly.sock")
    {:ok, %{uid: uid}} = File.stat(directory)

    start_supervised!(
      {Lilly.Ingress.Server,
       path: connector_path,
       audi_uid: uid,
       host_id: c.vm.host_id,
       backend: {Marshall.IngressConnectorFixture, {connector_port, self()}}}
    )

    listener =
      start_supervised!(
        {Audi.SSH.Listener,
         [
           port: 0,
           host_id: c.vm.host_id,
           host_key_dir: directory,
           key_cb: {Overalls.TestSSHKeyCallback, [proof: Audi.SSH.Proof]},
           backend:
             {Audi.SSH.ControlBackend,
              %{client: c.client, connector: {Audi.Connector, %{path: connector_path, uid: uid}}}}
         ]}
      )

    port = Audi.SSH.Listener.port(listener)

    File.write!(
      Path.join(directory, "known_hosts"),
      "[127.0.0.1]:#{port} " <>
        File.read!(Path.join(directory, "ssh_host_ed25519_key.pub"))
    )

    {:ok, connection} =
      :ssh.connect(
        ~c"127.0.0.1",
        port,
        [
          user: ~c"ignored",
          user_dir: String.to_charlist(directory),
          user_interaction: false,
          silently_accept_hosts: false,
          auth_methods: ~c"publickey"
        ],
        2000
      )

    on_exit(fn -> :ssh.close(connection) end)
    {:ok, channel} = :ssh_connection.session_channel(connection, 1000)

    assert :success =
             :ssh_connection.exec(
               connection,
               channel,
               String.to_charlist("connect " <> c.label),
               3000
             )

    assert :ok = :ssh_connection.send(connection, channel, "inner-ssh-bytes", 1000)
    assert_receive {:ssh_cm, ^connection, {:data, ^channel, 0, "inner-ssh-bytes"}}, 2000
    assert {:ok, _} = Marshall.SSH.remove_key(%{id: key.id}, actor: c.owner)
    # Key removal commits a user hint; the sandbox never commits pg_notify, so
    # deliver it as the relay would. The gateway renews at once and ends the
    # stream instead of waiting for its fifteen-second periodic renewal.
    Marshall.Control.Hints.deliver(%{"kind" => "user", "id" => c.owner.id})
    assert_receive :connector_closed, 6000
    assert_receive {:ssh_cm, ^connection, {:closed, ^channel}}, 1000
  end

  test "redirects never receive a second credential-bearing request", c do
    test = self()

    witness =
      spawn_link(fn ->
        receive do
          :request_received -> send(test, :target_received)
        end
      end)

    target = listener({Reply, {witness, 200, "{}", []}})
    source = listener({Reply, {self(), 302, "", [{"location", target <> "/api/control/v1"}]}})
    {:ok, client} = client(source, c.token, :dns, cacertfile: @ca)
    assert {:error, :transport_error} = Client.identity(client)
    assert_receive :request_received
    refute_receive :target_received, 500
  end

  test "oversized responses and malformed identities are bounded", c do
    for {body, expected} <- [
          {Jason.encode!(%{version: 1, padding: String.duplicate("x", 4097)}),
           :message_too_large},
          {"{}", :invalid_message}
        ] do
      url = listener({Reply, {self(), 200, body, []}})
      {:ok, client} = client(url, c.token, :dns, cacertfile: @ca)
      assert {:error, ^expected} = Client.identity(client)
    end
  end

  test "plaintext, userinfo, application paths and malformed host binding are invalid", c do
    for url <- [
          "http://127.0.0.1",
          "https://user:pass@example.test",
          "https://example.test/path",
          "https://example.test?token=x",
          "https://example.test#fragment"
        ] do
      assert {:error, :invalid_configuration} = Client.new(url, c.token, :dns)
    end

    assert {:error, :invalid_configuration} =
             Client.new("https://example.test", c.token, :gateway)
  end

  # A configured client with its control link started; the link may never
  # connect (untrusted certificate, refused bind), which tests then observe.
  @spec client(String.t(), binary(), :dns | :gateway, keyword()) ::
          {:ok, Client.t()} | {:error, :invalid_configuration}
  defp client(url, token, role, options \\ []) do
    control = :"transport_control_#{System.unique_integer([:positive])}"

    with {:ok, client} <- Client.new(url, token, role, Keyword.put(options, :control, control)) do
      start_supervised!({Audi.Control.Link, client}, id: control)
      ready(control, 50)
      {:ok, client}
    end
  end

  @spec ready(atom(), non_neg_integer()) :: :ok
  defp ready(_control, 0), do: :ok

  defp ready(control, attempts) do
    unless OverallsProtocol.Control.Client.ready?(control) do
      Process.sleep(20)
      ready(control, attempts - 1)
    end

    :ok
  end

  defp listener(plug, ip \\ {127, 0, 0, 1}) do
    server =
      start_supervised!(
        {Bandit,
         plug: plug,
         scheme: :https,
         ip: ip,
         port: 0,
         startup_log: false,
         certfile: @certificate,
         keyfile: @key},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    "https://#{:inet.ntoa(ip)}:#{port}"
  end

  defp ssh_fixture do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {token, _} = Ingress.Token.issue()

    {:ok, _} =
      Ingress.configure_service(
        %{name: "ssh-transport", role: :gateway, host_id: fixture.vm.host_id, token: token},
        actor: SystemActor.compute()
      )

    public_key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 42::256>>)
    {:ok, key} = Marshall.SSH.add_key(%{public_key: public_key}, actor: fixture.owner)
    [endpoint] = Marshall.Compute.Ledger.read!(Ingress.Endpoint, vm_id: fixture.vm.id)

    {:ok, client} =
      client(listener(MarshallWeb.ControlAPI), token, :gateway,
        host_id: fixture.vm.host_id,
        cacertfile: @ca
      )

    Map.merge(fixture, %{client: client, key: key, public_key: public_key, label: endpoint.label})
  end

  @spec eventually((-> boolean()), non_neg_integer()) :: boolean()
  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end
end
