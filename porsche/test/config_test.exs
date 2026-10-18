defmodule Porsche.ConfigTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  @token "porsche_gateway_" <> Base.url_encode64(<<0::256>>, padding: false)

  setup do
    directory =
      Path.join(System.tmp_dir!(), "porsche-config-#{System.unique_integer([:positive])}")

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
      "public_origin" => "https://overalls.example.test/",
      "credential_file" => credential,
      "host_key_dir" => directory
    }

    File.write!(path, JSON.encode!(value))
    %{directory: directory, path: path, value: value, credential: credential, key: key}
  end

  test "public operator config loads a separate private credential and stable host key", c do
    assert {:ok, options} = Porsche.Config.load(c.path)
    assert options[:port] == 22
    assert options[:bind] == {0, 0, 0, 0}
    assert options[:public_origin] == "https://overalls.example.test"
    assert options[:host_key_dir] == c.directory
    refute inspect(options) =~ @token

    assert {:ok, [{Porsche.Control.Link, %Porsche.Client{}}, {Porsche.Listener, ^options}]} =
             Porsche.Application.listener_children(c.path)

    assert {:ok, []} = Porsche.Application.listener_children(nil)

    assert {:error, :invalid_runtime_configuration} =
             Porsche.Application.listener_children(c.path <> "-missing")
  end

  test "credentials and private host keys reject public permissions, hardlinks and symlinks", c do
    for path <- [c.credential, c.key] do
      File.chmod!(path, 0o644)
      assert {:error, :invalid_runtime_configuration} = Porsche.Config.load(c.path)
      File.chmod!(path, 0o600)
      linked = path <> "-linked"
      File.ln!(path, linked)
      assert {:error, :invalid_runtime_configuration} = Porsche.Config.load(c.path)
      File.rm!(linked)
    end

    File.rename!(c.credential, c.credential <> "-real")
    File.ln_s!(c.credential <> "-real", c.credential)
    assert {:error, :invalid_runtime_configuration} = Porsche.Config.load(c.path)
  end

  test "configured private status socket starts after the listener", c do
    status_directory = Path.join(c.directory, "status")
    File.mkdir!(status_directory)
    File.chmod!(status_directory, 0o700)
    socket = Path.join(status_directory, "status.sock")
    File.write!(c.path, JSON.encode!(Map.put(c.value, "status_socket", socket)))

    assert {:ok,
            [
              {Porsche.Control.Link, %Porsche.Client{}},
              {Porsche.Listener, listener},
              {Porsche.StatusServer, status}
            ]} = Porsche.Application.listener_children(c.path)

    refute Keyword.has_key?(listener, :status_socket)
    assert status[:path] == socket
    File.chmod!(status_directory, 0o755)
    assert {:error, :invalid_runtime_configuration} = Porsche.Config.load(c.path)
  end

  test "untrusted parents and a symlinked or writable configuration are rejected", c do
    File.chmod!(c.path, 0o666)
    assert {:error, :invalid_runtime_configuration} = Porsche.Config.load(c.path)
    File.chmod!(c.path, 0o644)
    File.chmod!(c.directory, 0o777)
    assert {:error, :invalid_runtime_configuration} = Porsche.Config.load(c.path)
    File.chmod!(c.directory, 0o700)
    linked = c.path <> "-link"
    File.ln_s!(c.path, linked)
    assert {:error, :invalid_runtime_configuration} = Porsche.Config.load(linked)
  end

  test "closed fields, transport, addresses, ports and bounded files fail closed", c do
    for extra <- [
          %{"credential" => @token},
          %{"unknown" => true},
          %{"version" => 2},
          %{"control_plane" => "http://127.0.0.1"},
          %{"public_origin" => "https://host/path"},
          %{"bind" => "localhost"},
          %{"bind" => "::1"},
          %{"bind" => "127.1"},
          %{"bind" => "010.40.0.2"},
          %{"port" => 0},
          %{"port" => 65_536},
          %{"cacertfile" => "/missing-ca"},
          %{"host_key_dir" => "/tmp/../tmp"}
        ] do
      File.write!(c.path, JSON.encode!(Map.merge(c.value, extra)))
      assert {:error, :invalid_runtime_configuration} = Porsche.Config.load(c.path)
    end

    File.write!(c.path, String.duplicate("x", 16_385))
    assert {:error, :invalid_runtime_configuration} = Porsche.Config.load(c.path)
    File.write!(c.path, JSON.encode!(c.value))
    File.chmod!(c.credential, 0o600)
    File.write!(c.credential, @token <> "\n\n")
    assert {:error, :invalid_runtime_configuration} = Porsche.Config.load(c.path)
    File.write!(c.credential, String.duplicate("x", 257))
    assert {:error, :invalid_runtime_configuration} = Porsche.Config.load(c.path)
  end

  test "arbitrary configuration bytes produce a fixed error or a secret-free inspected result",
       c do
    check all(bytes <- binary(max_length: 20_000), max_runs: 40) do
      File.write!(c.path, bytes)

      case Porsche.Config.load(c.path) do
        {:error, :invalid_runtime_configuration} -> :ok
        {:ok, options} -> refute inspect(options) =~ @token
      end
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
          "/CN=porsche-test-ca",
          "-keyout",
          Path.join(c.directory, "ca.key"),
          "-out",
          ca
        ],
        stderr_to_stdout: true
      )

    File.write!(c.path, JSON.encode!(Map.put(c.value, "cacertfile", ca)))
    assert {:ok, _} = Porsche.Config.load(c.path)
    File.chmod!(ca, 0o666)
    assert {:error, :invalid_runtime_configuration} = Porsche.Config.load(c.path)
    File.chmod!(ca, 0o644)
    File.write!(ca, "not a certificate")
    assert {:error, :invalid_runtime_configuration} = Porsche.Config.load(c.path)
  end
end
