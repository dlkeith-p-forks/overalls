defmodule Marshall.Operations.RuntimeConfigTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Operations.RuntimeConfig

  test "public Inception startup reads a bounded public file and fails closed" do
    directory =
      Path.join(System.tmp_dir!(), "inception-public-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "public.json")
    env = %{"MARSHALL_INCEPTION_PUBLIC_FILE" => path}
    assert {:ok, nil} = RuntimeConfig.inception_public(%{})
    assert {:error, :invalid_inception_public} = RuntimeConfig.inception_public(env)

    assert {:error, :invalid_inception_public} =
             RuntimeConfig.inception_public(%{"MARSHALL_INCEPTION_PUBLIC_FILE" => directory})

    value = %{
      "issuer" => "https://ca.example/directory",
      "accept_terms" => true,
      "nameservers" => [
        %{"name" => "ns1.example", "address" => "192.0.2.53", "port" => 53},
        %{"name" => "ns2.example", "address" => "198.51.100.53", "port" => 53}
      ],
      "mailbox" => "hostmaster.example",
      "issuer_ca_pem" => nil,
      "trust_pem" => nil
    }

    File.write!(path, JSON.encode!(value))
    assert {:ok, ^value} = RuntimeConfig.inception_public(env)

    for invalid <- [
          "{",
          "null",
          JSON.encode!(Map.put(value, "credential", "forbidden")),
          String.duplicate(" ", 65_537)
        ] do
      File.write!(path, invalid)
      assert {:error, :invalid_inception_public} = RuntimeConfig.inception_public(env)
    end
  end

  property "default images accept only canonical identities or explicit absence" do
    value = draw("value", one_of([binary(max_length: 128), integer()]))
    result = RuntimeConfig.default_image(%{"MARSHALL_DEFAULT_IMAGE_ID" => value})

    cond do
      value == "" -> assert result == {:ok, nil}
      OverallsProtocol.ImageManifest.id?(value) -> assert result == {:ok, value}
      true -> assert result == {:error, :invalid_default_image}
    end

    assert {:ok, nil} = RuntimeConfig.default_image(%{})
    id = "sha256:" <> String.duplicate("a", 64)
    assert {:ok, ^id} = RuntimeConfig.default_image(%{"MARSHALL_DEFAULT_IMAGE_ID" => id})
  end

  @fixtures Path.expand("../../fixtures/tls", __DIR__)

  defp environment do
    %{
      "DATABASE_URL" => "ecto://operator:private-password@localhost/marshall",
      "MARSHALL_REPLICA_COUNT" => "3",
      "MARSHALL_DB_CONNECTION_BUDGET" => "43",
      "MARSHALL_INSTANCE_ID" => "marshall-01"
    }
  end

  test "production verifies PostgreSQL identity and bounds each replica's connections" do
    assert {:ok, config} = RuntimeConfig.from_env(environment())
    assert config.repo[:ssl][:verify] == :verify_peer
    assert config.repo[:ssl][:server_name_indication] == ~c"localhost"
    assert config.repo[:target_server_type] == :primary
    assert config.repo[:pool_size] == 10
    assert config.repo[:pool_count] == 1

    assert config.repo[:parameters] == [
             application_name: "marshall:marshall-01",
             synchronous_commit: "on",
             idle_in_transaction_session_timeout: "15s",
             client_connection_check_interval: "1s",
             tcp_keepalives_idle: "15s",
             tcp_keepalives_interval: "5s",
             tcp_keepalives_count: "3",
             tcp_user_timeout: "15s"
           ]

    assert config.endpoint == [server: false, http: false, https: false]
    assert config.fleet_listeners == []
    refute inspect(config) =~ "private-password"
  end

  test "database URL cannot override transport, pools, parameters or manufacture atoms" do
    for suffix <- ["?ssl=false", "?pool_size=1000", "?unrecognized_key=value", "#ssl=false"] do
      assert {:error, :invalid_deployment_configuration} =
               RuntimeConfig.from_env(Map.update!(environment(), "DATABASE_URL", &(&1 <> suffix)))
    end

    for url <- [
          "postgres://localhost/db",
          "http://user@localhost/db",
          "ecto://user@/db",
          "ecto://user@host/"
        ] do
      assert {:error, :invalid_deployment_configuration} =
               RuntimeConfig.from_env(Map.put(environment(), "DATABASE_URL", url))
    end
  end

  test "plaintext is explicit and limited to literal loopback destinations" do
    for host <- ["localhost", "127.0.0.1"] do
      assert {:ok, config} =
               RuntimeConfig.from_env(
                 Map.merge(environment(), %{
                   "DATABASE_URL" => "ecto://user@#{host}/database",
                   "MARSHALL_DB_TLS" => "loopback"
                 })
               )

      assert config.repo[:ssl] == false
      assert config.repo[:socket_options] == [:inet]
    end

    for host <- ["database.example.test", "127.0.0.1.example.test", "10.0.0.1", "[::1]"] do
      assert {:error, :invalid_deployment_configuration} =
               RuntimeConfig.from_env(
                 Map.merge(environment(), %{
                   "DATABASE_URL" => "ecto://user@#{host}/database",
                   "MARSHALL_DB_TLS" => "loopback"
                 })
               )
    end

    assert {:error, _} =
             RuntimeConfig.from_env(Map.put(environment(), "MARSHALL_DB_TLS", "disable"))

    assert {:error, _} = RuntimeConfig.from_env(Map.put(environment(), "ECTO_IPV6", "true"))
    assert {:error, _} = RuntimeConfig.from_env(Map.put(environment(), "ECTO_IPV6", "invalid"))
  end

  test "verified database transport and listeners reject IPv6" do
    assert {:ok, config} = RuntimeConfig.from_env(environment())
    assert config.repo[:socket_options] == [:inet]

    for host <- ["::1", "2001:db8::1", "::ffff:192.0.2.1"] do
      assert {:error, :invalid_deployment_configuration} =
               RuntimeConfig.from_env(
                 Map.put(environment(), "DATABASE_URL", "ecto://user@[#{host}]/database")
               )

      assert {:error, :invalid_deployment_configuration} =
               RuntimeConfig.from_env(Map.put(environment(), "MARSHALL_BIND_IP", host))
    end
  end

  test "serving needs paired TLS files and explicit optional redirect ports" do
    env = Map.put(environment(), "PHX_SERVER", "true")
    assert {:error, _} = RuntimeConfig.from_env(env)

    env =
      Map.merge(env, %{
        "MARSHALL_TLS_CERTFILE" => Path.join(@fixtures, "localhost.pem"),
        "MARSHALL_TLS_KEYFILE" => Path.join(@fixtures, "localhost.key"),
        "MARSHALL_TLS_PORT" => "4401"
      })

    assert {:ok, config} = RuntimeConfig.from_env(env)
    assert config.endpoint[:server]
    assert config.endpoint[:https][:ip] == {127, 0, 0, 1}
    assert config.endpoint[:https][:port] == 4401
    assert config.endpoint[:http] == false
    assert hd(config.fleet_listeners)[:ip] == {127, 0, 0, 1}
    assert hd(config.fleet_listeners)[:port] == 5443
    assert hd(config.fleet_listeners)[:scheme] == :https
    assert hd(config.fleet_listeners)[:plug] == MarshallWeb.FleetEndpoint
    assert hd(config.fleet_listeners)[:certfile] == config.endpoint[:https][:certfile]
    assert {:ok, config} = RuntimeConfig.from_env(Map.put(env, "PORT", "4001"))
    assert config.endpoint[:http][:port] == 4001
    assert {:error, _} = RuntimeConfig.from_env(Map.put(env, "PORT", "4401"))

    assert {:error, _} =
             RuntimeConfig.from_env(Map.put(env, "MARSHALL_BIND_IP", "public.example.test"))

    assert {:ok, config} = RuntimeConfig.from_env(Map.put(env, "PHX_SERVER", "false"))
    refute config.endpoint[:server]
    assert config.fleet_listeners == []
  end

  test "fleet listener refuses wildcard, IPv6 and browser socket collisions" do
    env =
      Map.merge(environment(), %{
        "PHX_SERVER" => "true",
        "MARSHALL_TLS_CERTFILE" => Path.join(@fixtures, "localhost.pem"),
        "MARSHALL_TLS_KEYFILE" => Path.join(@fixtures, "localhost.key")
      })

    for address <- ["0.0.0.0", "::1", "::ffff:127.0.0.1", "localhost", "127.1"] do
      assert {:error, :invalid_deployment_configuration} =
               RuntimeConfig.from_env(Map.put(env, "MARSHALL_FLEET_BIND_IP", address))
    end

    for overrides <- [
          %{"MARSHALL_FLEET_TLS_PORT" => "4443"},
          %{"PORT" => "5443"},
          %{"MARSHALL_BIND_IP" => "0.0.0.0", "MARSHALL_FLEET_TLS_PORT" => "4443"},
          %{"MARSHALL_FLEET_TLS_PORT" => "0"},
          %{"MARSHALL_FLEET_TLS_PORT" => "65536"}
        ] do
      assert {:error, :invalid_deployment_configuration} =
               RuntimeConfig.from_env(Map.merge(env, overrides))
    end

    assert {:ok, config} =
             RuntimeConfig.from_env(
               Map.merge(env, %{
                 "MARSHALL_FLEET_BIND_IP" => "10.90.0.1",
                 "MARSHALL_FLEET_TLS_PORT" => "4443"
               })
             )

    assert hd(config.fleet_listeners)[:ip] == {10, 90, 0, 1}

    assert {:ok, config} =
             RuntimeConfig.from_env(
               Map.merge(env, %{
                 "MARSHALL_FLEET_BIND_IP" => "10.90.0.1",
                 "MARSHALL_FLEET_LOOPBACK" => "true"
               })
             )

    assert Enum.map(config.fleet_listeners, & &1[:ip]) == [{10, 90, 0, 1}, {127, 0, 0, 1}]
    assert Enum.all?(config.fleet_listeners, &(&1[:port] == 5443))

    assert {:error, :invalid_deployment_configuration} =
             RuntimeConfig.from_env(
               Map.merge(env, %{
                 "MARSHALL_FLEET_BIND_IP" => "10.90.0.1",
                 "MARSHALL_FLEET_TLS_PORT" => "4443",
                 "MARSHALL_FLEET_LOOPBACK" => "true"
               })
             )

    assert {:ok, config} =
             RuntimeConfig.from_env(Map.put(env, "MARSHALL_FLEET_LOOPBACK", "true"))

    assert length(config.fleet_listeners) == 1

    assert {:error, :invalid_deployment_configuration} =
             RuntimeConfig.from_env(Map.put(env, "MARSHALL_FLEET_LOOPBACK", "invalid"))
  end

  test "a single instance retains verified TLS and its full connection budget" do
    env =
      Map.merge(environment(), %{
        "MARSHALL_REPLICA_COUNT" => "1",
        "MARSHALL_DB_CONNECTION_BUDGET" => "21"
      })

    assert {:ok, config} = RuntimeConfig.from_env(env)
    assert config.replicas == 1
    assert config.repo[:ssl][:verify] == :verify_peer
    assert config.repo[:parameters][:synchronous_commit] == "on"

    assert {:error, :invalid_deployment_configuration} =
             RuntimeConfig.from_env(Map.put(env, "MARSHALL_DB_CONNECTION_BUDGET", "20"))
  end

  property "1–100 replicas fit only when the pool, notifier and operator budget fits" do
    replicas = draw("replicas", integer(0..150))
    pool = draw("pool", integer(1..150))
    budget = draw("budget", integer(1..20000))

    result =
      RuntimeConfig.from_env(
        Map.merge(environment(), %{
          "MARSHALL_REPLICA_COUNT" => to_string(replicas),
          "POOL_SIZE" => to_string(pool),
          "MARSHALL_DB_CONNECTION_BUDGET" => to_string(budget)
        })
      )

    expected = replicas in 1..100 and pool in 1..100 and replicas * (pool + 1) + 10 <= budget
    assert match?({:ok, _}, result) == expected
  end

  property "malformed operator inputs return a fixed error without reflecting secrets" do
    key =
      draw(
        "key",
        member_of([
          "DATABASE_URL",
          "MARSHALL_REPLICA_COUNT",
          "POOL_SIZE",
          "MARSHALL_DB_CONNECTION_BUDGET",
          "MARSHALL_INSTANCE_ID",
          "PHX_SERVER",
          "MARSHALL_BIND_IP"
        ])
      )

    value = draw("value", one_of([integer(), constant(nil), list_of(integer(), max_length: 5)]))

    assert {:error, :invalid_deployment_configuration} =
             RuntimeConfig.from_env(Map.put(environment(), key, value))
  end
end
