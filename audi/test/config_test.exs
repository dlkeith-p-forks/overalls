defmodule Audi.ConfigTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  @token "audi_service_" <> Base.url_encode64(<<0::256>>, padding: false)

  test "control clients reject IPv6 literals for both service roles" do
    for origin <- ["https://[::1]", "https://[2001:db8::1]", "https://[::ffff:127.0.0.1]"] do
      assert {:error, :invalid_configuration} = Audi.Control.Client.new(origin, @token, :dns)

      assert {:error, :invalid_configuration} =
               Audi.Control.Client.new(origin, @token, :gateway,
                 host_id: "11111111-1111-4111-8111-111111111111"
               )
    end
  end

  setup do
    directory =
      Path.join(System.tmp_dir!(), "audi-config-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    key = Path.join(directory, "ssh_host_ed25519_key")
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key])
    credential = Path.join(directory, "gateway")
    File.write!(credential, @token <> "\n")
    File.chmod!(credential, 0o400)
    path = Path.join(directory, "config.json")

    value = %{
      "version" => 1,
      "control_plane" => "https://marshall.example.test",
      "role" => "gateway",
      "host_id" => "11111111-1111-4111-8111-111111111111",
      "connector_path" => "/run/lilly/audi.sock",
      "connector_uid" => 0,
      "credential_file" => credential,
      "host_key_dir" => directory
    }

    File.write!(path, JSON.encode!(value))
    %{directory: directory, path: path, value: value, credential: credential, key: key}
  end

  test "guidance uses only a separately configured validated public origin", c do
    assert {:ok, options} = Audi.Config.load(c.path)
    assert options[:public_origin] == nil
    value = Map.put(c.value, "public_origin", "https://public.example.test")
    File.write!(c.path, JSON.encode!(value))
    assert {:ok, options} = Audi.Config.load(c.path)
    assert options[:public_origin] == "https://public.example.test"
    File.write!(c.path, JSON.encode!(%{value | "public_origin" => "https://private:secret@host"}))
    assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
  end

  test "public operator config loads a separate private credential and stable host key", c do
    assert {:ok, options} = Audi.Config.load(c.path)
    assert options[:port] == 22
    assert options[:bind] == {0, 0, 0, 0}
    assert options[:host_id] == c.value["host_id"]
    assert {Audi.SSH.ControlBackend, %{client: client, connector: connector}} = options[:backend]
    assert client.role == :gateway
    assert client.host_id == options[:host_id]
    assert connector == {Audi.Connector, %{path: "/run/lilly/audi.sock", uid: 0}}
    assert options[:host_key_dir] == c.directory
    refute inspect(options) =~ @token

    assert {:ok,
            [
              {Audi.Control.Link, ^client},
              {Audi.SSH.Listener, ^options},
              {Audi.SSH.KeyPublisher, publisher}
            ]} = Audi.Application.listener_children(c.path)

    assert publisher[:client] == client
    assert publisher[:host_key_dir] == c.directory
    assert {:ok, []} = Audi.Application.listener_children(nil)

    assert {:error, :invalid_runtime_configuration} =
             Audi.Application.listener_children(c.path <> "-missing")
  end

  test "TLS startup constructs the fleet worker after the in-memory store and listeners", c do
    ca = Path.expand("../../marshall/test/fixtures/tls/ca.pem", __DIR__)

    tls = %{
      "zone" => "apps.example",
      "browser_origin" => "https://control.example.test",
      "trust_file" => ca
    }

    File.write!(c.path, JSON.encode!(Map.put(c.value, "tls", tls)))
    assert {:ok, children} = Audi.Application.listener_children(c.path)

    assert [
             {Audi.Control.Link, _},
             {Audi.SSH.Listener, _},
             {Audi.SSH.KeyPublisher, _},
             {OverallsProtocol.View, view},
             {Audi.TLS.Store, store},
             %{id: :audi_http},
             %{id: :audi_https},
             {Task.Supervisor, tasks},
             {Audi.TLS.FleetWorker, worker}
           ] = children

    assert store[:name] == Audi.TLS.Store and tasks[:max_children] == 20
    assert view[:name] == Audi.TLS.Store.view(Audi.TLS.Store)
    assert worker[:probe_peer] == {{127, 0, 0, 1}, 443}

    for {bind, expected} <- [{"0.0.0.0", {127, 0, 0, 1}}, {"136.243.69.37", {136, 243, 69, 37}}] do
      value =
        Map.merge(c.value, %{
          "tls" => tls,
          "bind" => bind,
          "status_socket" => Path.join(c.directory, "status.sock")
        })

      File.write!(c.path, JSON.encode!(value))
      assert {:ok, children} = Audi.Application.listener_children(c.path)

      assert {Audi.TLS.FleetWorker, options} =
               Enum.find(children, &match?({Audi.TLS.FleetWorker, _}, &1))

      assert options[:probe_peer] == {expected, 443}

      assert {Audi.StatusServer, status} = List.last(children)
      assert status[:ports] == [{expected, 80}, {expected, 443}]
    end

    trusted_tls = Map.put(tls, "trusted_proxy_peer", "10.40.0.1")
    File.write!(c.path, JSON.encode!(Map.put(c.value, "tls", trusted_tls)))
    assert {:ok, configured} = Audi.Config.load(c.path)
    assert configured[:tls][:trusted_proxy_peer] == {10, 40, 0, 1}
    assert {:ok, children} = Audi.Application.listener_children(c.path)
    https_child = Enum.find(children, &match?(%{id: :audi_https}, &1))
    assert {Audi.HTTP.Listener, :start_link, [https_options]} = https_child.start
    assert https_options[:trusted_proxy_peer] == {10, 40, 0, 1}
    assert https_options[:browser_origin] == "https://control.example.test"

    for invalid <- [
          Map.delete(tls, "browser_origin"),
          Map.put(tls, "browser_origin", "http://control.example.test"),
          Map.put(tls, "browser_origin", "https://control.example.test:5443/audi"),
          Map.put(tls, "browser_origin", "https://user@control.example.test"),
          Map.put(tls, "browser_origin", "https://[::1]"),
          Map.put(tls, "browser_origin", "https://control.example.test:0"),
          Map.put(tls, "browser_origin", c.value["control_plane"]),
          Map.put(tls, "trusted_proxy_peer", "::1"),
          Map.put(tls, "trusted_proxy_peer", "10.040.0.1"),
          Map.put(tls, "trusted_proxy_peer", true),
          Map.put(tls, "private_key", "inline"),
          Map.put(tls, "issuer", "https://ca.example/directory"),
          Map.put(tls, "https_port", 22),
          Map.put(tls, "directory", "/var/lib/audi/certificates")
        ] do
      File.write!(c.path, JSON.encode!(Map.put(c.value, "tls", invalid)))
      assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
    end
  end

  test "private status configuration reaches the gateway supervisor and rejects unsafe paths",
       c do
    path = Path.join(c.directory, "status.sock")
    File.write!(c.path, JSON.encode!(Map.put(c.value, "status_socket", path)))
    assert {:ok, children} = Audi.Application.listener_children(c.path)
    assert {Audi.StatusServer, options} = List.last(children)
    assert options[:path] == path
    assert options[:role] == :gateway
    File.chmod!(c.directory, 0o755)
    assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
  end

  test "DNS role has a closed schema and starts an empty replica before its listeners", c do
    value = %{
      "version" => 1,
      "role" => "dns",
      "control_plane" => "https://marshall.example.test",
      "credential_file" => c.credential,
      "zone" => "apps.example",
      "nameservers" => ["ns1.example", "ns2.example"],
      "mailbox" => "hostmaster.example"
    }

    File.write!(c.path, JSON.encode!(value))
    assert {:ok, options} = Audi.Config.load(c.path)
    assert options[:role] == :dns
    assert options[:port] == 53

    assert {:ok,
            [
              {Audi.Control.Link, %Audi.Control.Client{role: :dns}},
              {OverallsProtocol.View, directory_view},
              {Audi.DNS.Directory, directory},
              {Audi.DNS.Server, server},
              {Audi.DNS.Replica, replica}
            ]} =
             Audi.Application.listener_children(c.path)

    assert replica[:client].role == :dns
    assert replica[:zone] == "apps.example"
    refute inspect(replica) =~ @token

    start_supervised!({OverallsProtocol.View, directory_view})
    start_supervised!({Audi.DNS.Directory, directory})
    listener = start_supervised!({Audi.DNS.Server, Keyword.put(server, :port, 0)})
    assert Audi.DNS.Server.port(listener) > 0
    assert Audi.DNS.Directory.lookup(Audi.DNS.Directory, "apps.example") == :stale

    status_path = Path.join(c.directory, "dns-status.sock")
    File.write!(c.path, JSON.encode!(Map.put(value, "status_socket", status_path)))
    assert {:ok, children} = Audi.Application.listener_children(c.path)
    assert {Audi.StatusServer, status} = List.last(children)
    assert status[:path] == status_path
    assert status[:role] == :dns

    for extra <- [
          %{"zone" => "Bad.example"},
          %{"zone" => "a..example"},
          %{"nameservers" => ["ns1.example"]},
          %{"nameservers" => ["ns1.example", "ns1.example"]},
          %{"mailbox" => "user@example"},
          %{"entries" => %{}},
          %{"host_key_dir" => c.directory},
          %{"credential_file" => c.credential <> "-missing"},
          %{"control_plane" => "http://marshall.example.test"},
          %{"cacertfile" => c.credential},
          %{"port" => 0},
          %{"bind" => "localhost"},
          %{"bind" => "::1"},
          %{"bind" => "::ffff:192.0.2.1"}
        ] do
      File.write!(c.path, JSON.encode!(Map.merge(value, extra)))
      assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
    end
  end

  test "published host identity comes from the private key, never its public sidecar", c do
    {:ok, expected} = OverallsProtocol.SSHKey.parse(File.read!(c.key <> ".pub"))
    assert {:ok, key} = Audi.SSH.HostKey.public(c.directory)
    assert key == expected.public_key
    File.write!(c.key <> ".pub", "untrusted replacement")
    assert {:ok, ^key} = Audi.SSH.HostKey.public(c.directory)
    File.chmod!(c.key, 0o600)
    File.write!(c.key, "invalid private key")
    assert {:error, :invalid_host_key} = Audi.SSH.HostKey.public(c.directory)
  end

  test "credentials and private host keys reject public permissions, hardlinks and symlinks", c do
    for path <- [c.credential, c.key] do
      File.chmod!(path, 0o644)
      assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
      File.chmod!(path, 0o600)
      linked = path <> "-linked"
      File.ln!(path, linked)
      assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
      File.rm!(linked)
    end

    File.rename!(c.credential, c.credential <> "-real")
    File.ln_s!(c.credential <> "-real", c.credential)
    assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
  end

  test "untrusted parents and a symlinked or writable configuration are rejected", c do
    File.chmod!(c.path, 0o666)
    assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
    File.chmod!(c.path, 0o644)
    File.chmod!(c.directory, 0o777)
    assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
    File.chmod!(c.directory, 0o700)
    linked = c.path <> "-link"
    File.ln_s!(c.path, linked)
    assert {:error, :invalid_runtime_configuration} = Audi.Config.load(linked)
  end

  test "closed fields, transport, addresses, ports and bounded files fail closed", c do
    for extra <- [
          %{"credential" => @token},
          %{"unknown" => true},
          %{"version" => 2},
          %{"control_plane" => "http://127.0.0.1"},
          %{"role" => "dns"},
          %{"host_id" => "invalid"},
          %{"connector_path" => "relative.sock"},
          %{"connector_path" => "/tmp/../tmp/a.sock"},
          %{"connector_path" => "/" <> String.duplicate("x", 107)},
          %{"connector_uid" => -1},
          %{"connector_uid" => 4_294_967_295},
          %{"connector_uid" => "root"},
          %{"backend" => "Other.Module"},
          %{"bind" => "localhost"},
          %{"bind" => "::1"},
          %{"bind" => "::ffff:192.0.2.1"},
          %{"port" => 0},
          %{"port" => 65_536},
          %{"cacertfile" => "/missing-ca"},
          %{"host_key_dir" => "/tmp/../tmp"}
        ] do
      File.write!(c.path, JSON.encode!(Map.merge(c.value, extra)))
      assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
    end

    File.write!(c.path, String.duplicate("x", 16_385))
    assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
    File.write!(c.path, JSON.encode!(c.value))
    File.chmod!(c.credential, 0o600)
    File.write!(c.credential, @token <> "\n\n")
    assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
    File.write!(c.credential, String.duplicate("x", 257))
    assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
  end

  property "arbitrary configuration bytes produce a fixed error or a secret-free inspected result",
           c do
    bytes = draw("bytes", binary(max_length: 20000))

    File.write!(c.path, bytes)

    case Audi.Config.load(c.path) do
      {:error, :invalid_runtime_configuration} -> :ok
      {:ok, options} -> refute inspect(options) =~ @token
    end
  end

  test "a custom authority must be an immutable-to-other-users PEM certificate file", c do
    ca = Path.join(c.directory, "ca.pem")

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-days",
          "1",
          "-subj",
          "/CN=audi-test-ca",
          "-keyout",
          Path.join(c.directory, "ca.key"),
          "-out",
          ca
        ],
        stderr_to_stdout: true
      )

    File.write!(c.path, JSON.encode!(Map.put(c.value, "cacertfile", ca)))
    assert {:ok, _} = Audi.Config.load(c.path)
    File.chmod!(ca, 0o666)
    assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
    File.chmod!(ca, 0o644)
    File.write!(ca, "not a certificate")
    assert {:error, :invalid_runtime_configuration} = Audi.Config.load(c.path)
  end
end
