defmodule Susan.ConfigTest do
  use ExUnit.Case, async: true

  alias Susan.Config

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    credentials = Path.join(dir, "credentials")
    File.mkdir!(credentials)
    File.chmod!(credentials, 0o700)
    ec = :public_key.generate_key({:namedCurve, :secp256r1})
    rsa = :public_key.generate_key({:rsa, 2048, 65_537})

    secrets = %{
      "APNS_KEY_P8" => pem(:ECPrivateKey, ec),
      "APNS_KEY_ID" => "ABCDEFGHIJ\n",
      "APNS_TEAM_ID" => "TEAM123456",
      "FCM_SERVICE_ACCOUNT_JSON" =>
        JSON.encode!(%{
          "type" => "service_account",
          "project_id" => "overalls-test",
          "client_email" => "relay@overalls-test.iam.gserviceaccount.com",
          "private_key" => pem(:RSAPrivateKey, rsa),
          "token_uri" => "https://oauth2.googleapis.com/token"
        }),
      "WNS_TENANT_ID" => "00000000-0000-4000-8000-0000000000AA\n",
      "WNS_CLIENT_ID" => "00000000-0000-4000-8000-000000000002",
      "WNS_CLIENT_SECRET" => "entra-client-secret-value",
      "SUSAN_PUSH_KEY_SIGNING_KEY" =>
        JSON.encode!(%{
          "active" => 1,
          "keys" => %{"1" => Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)}
        }),
      "DATABASE_URL" => "postgres://susan@localhost/susan"
    }

    Enum.each(secrets, fn {name, value} -> write(Path.join(credentials, name), value, 0o400) end)
    config = Path.join(dir, "config.json")

    write(
      config,
      JSON.encode!(%{
        "version" => 1,
        "port" => 4100,
        "apns_topics" => ["dev.overalls.mila"],
        "fcm_app_ids" => ["dev.overalls.mila"],
        "wns_app_ids" => ["dev.overalls.mila"]
      }),
      0o644
    )

    %{config: config, credentials: credentials, secrets: secrets}
  end

  defp pem(type, key), do: :public_key.pem_encode([:public_key.pem_entry_encode(type, key)])

  defp write(path, value, mode) do
    File.rm(path)
    File.write!(path, value)
    File.chmod!(path, mode)
  end

  test "loads a complete configuration and redacts it", ctx do
    assert {:ok, config} = Config.load(ctx.config, ctx.credentials)
    assert config.port == 4100 and config.apns.key_id == "ABCDEFGHIJ"
    assert config.fcm.project_id == "overalls-test"
    assert config.wns.tenant_id == "00000000-0000-4000-8000-0000000000aa"
    assert config.wns_app_ids == ["dev.overalls.mila"]
    assert config.repo[:database] == "susan"
    refute inspect(config) =~ "BEGIN"
    refute inspect(config) =~ "entra-client-secret"
  end

  test "a WNS-only relay needs only the WNS credentials", ctx do
    for name <- ~w(APNS_KEY_P8 APNS_KEY_ID APNS_TEAM_ID FCM_SERVICE_ACCOUNT_JSON),
        do: File.rm!(Path.join(ctx.credentials, name))

    write(
      ctx.config,
      JSON.encode!(%{"version" => 1, "wns_app_ids" => ["dev.overalls.mila"]}),
      0o644
    )

    assert {:ok, config} = Config.load(ctx.config, ctx.credentials)
    assert config.apns == nil and config.fcm == nil and config.wns.client_id != nil
  end

  test "refuses unsafe or malformed secrets with one fixed error", ctx do
    cases = [
      fn -> File.chmod!(Path.join(ctx.credentials, "DATABASE_URL"), 0o644) end,
      fn -> File.rm!(Path.join(ctx.credentials, "APNS_KEY_ID")) end,
      fn ->
        target = Path.join(ctx.credentials, "APNS_TEAM_ID")
        File.rename!(target, target <> ".real")
        File.ln_s!(target <> ".real", target)
      end,
      fn -> write(Path.join(ctx.credentials, "APNS_KEY_P8"), "not a key", 0o400) end,
      fn ->
        account =
          ctx.secrets["FCM_SERVICE_ACCOUNT_JSON"]
          |> JSON.decode!()
          |> Map.put("token_uri", "https://evil.example/token")

        write(
          Path.join(ctx.credentials, "FCM_SERVICE_ACCOUNT_JSON"),
          JSON.encode!(account),
          0o400
        )
      end,
      fn ->
        write(
          Path.join(ctx.credentials, "SUSAN_PUSH_KEY_SIGNING_KEY"),
          ~s({"active":2,"keys":{"1":"AAAA"}}),
          0o400
        )
      end,
      fn -> write(Path.join(ctx.credentials, "DATABASE_URL"), "mysql://x/y", 0o400) end,
      fn -> write(Path.join(ctx.credentials, "WNS_TENANT_ID"), "../evil", 0o400) end,
      fn -> write(Path.join(ctx.credentials, "WNS_CLIENT_SECRET"), "short", 0o400) end,
      fn -> File.rm!(Path.join(ctx.credentials, "WNS_CLIENT_ID")) end,
      fn ->
        write(
          ctx.config,
          JSON.encode!(%{"version" => 1, "apns_topics" => ["a"], "debug" => true}),
          0o644
        )
      end,
      fn -> write(ctx.config, JSON.encode!(%{"version" => 1, "apns_topics" => []}), 0o644) end,
      fn ->
        write(
          ctx.config,
          JSON.encode!(%{"version" => 1, "apns_topics" => ["a"], "bind" => "0:0"}),
          0o644
        )
      end,
      fn -> File.chmod!(ctx.config, 0o666) end
    ]

    for mutate <- cases do
      {:ok, snapshot} = File.ls(ctx.credentials)
      before = Map.new(snapshot, &{&1, File.read!(Path.join(ctx.credentials, &1))})
      config_before = File.read!(ctx.config)
      mutate.()
      assert {:error, :invalid_runtime_configuration} = Config.load(ctx.config, ctx.credentials)
      # restore
      Enum.each(File.ls!(ctx.credentials), &File.rm!(Path.join(ctx.credentials, &1)))

      Enum.each(before, fn {name, value} ->
        write(Path.join(ctx.credentials, name), value, 0o400)
      end)

      write(ctx.config, config_before, 0o644)
    end

    assert {:ok, _} = Config.load(ctx.config, ctx.credentials)
    assert {:error, :invalid_runtime_configuration} = Config.load(ctx.config, "relative/dir")
    assert {:error, :invalid_runtime_configuration} = Config.load(nil, ctx.credentials)
  end
end
