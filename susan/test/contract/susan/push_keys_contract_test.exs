defmodule SusanPushKeysContractTest do
  use Covenant.Case, component: "susan.push_keys"

  alias Susan.{Fixtures, Keys, PushKey}

  @fields %{
    provider: :fcm,
    environment: :production,
    app_id: "dev.overalls.mila",
    deployment: "control.example.test",
    token: "fcm:token-value-0123456789abcdef0123456789",
    issued_at: 1_000
  }

  @tag obligation: "susan.push_keys.I1"
  test "any flipped byte is refused" do
    {:ok, encoded, _} = PushKey.seal(Fixtures.keyring(), @fields)
    raw = Base.url_decode64!(encoded, padding: false)

    for index <- 0..(byte_size(raw) - 1) do
      <<prefix::binary-size(^index), byte, rest::binary>> = raw

      tampered =
        Base.url_encode64(<<prefix::binary, Bitwise.bxor(byte, 1), rest::binary>>, padding: false)

      assert {:error, :unknown_key} = PushKey.open(Fixtures.keyring(), tampered, 1_000)
    end
  end

  @tag obligation: "susan.push_keys.I2"
  test "rotation keeps retained keys and every key expires after 90 days" do
    {:ok, old, _} = PushKey.seal(Fixtures.keyring(1), @fields)
    assert {:ok, %{keyring_id: 1}} = PushKey.open(Fixtures.keyring(2), old, 1_000)
    assert {:error, :expired_key} = PushKey.open(Fixtures.keyring(2), old, 1_001 + 90 * 86_400)
  end

  @tag obligation: "susan.push_keys.I3"
  test "issuance is closed and binds the deployment" do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Susan.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    config = Fixtures.config()
    source = :crypto.strong_rand_bytes(32)

    body = %{
      "provider" => "fcm",
      "token" => Fixtures.fcm_token(),
      "app_id" => "dev.overalls.mila",
      "environment" => "production",
      "deployment" => "a.example.test"
    }

    assert {201, %{"push_key" => key}} = Keys.issue(JSON.encode!(body), source, config, 5)
    assert {:ok, %{deployment: "a.example.test"}} = PushKey.open(config.keyring, key, 5)
    assert {400, _, _} = Keys.issue(JSON.encode!(Map.put(body, "x", 1)), source, config, 5)

    assert {400, _, _} =
             Keys.issue(JSON.encode!(%{body | "app_id" => "other.app"}), source, config, 5)
  end

  @tag obligation: "susan.push_keys.I4"
  @tag :tmp_dir
  test "a readable or symlinked secret is refused", %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    secret = Path.join(dir, "DATABASE_URL")
    File.write!(secret, "postgres://u@h/d")
    File.chmod!(secret, 0o644)
    assert :error = Susan.Credentials.secret(dir, "DATABASE_URL", 100)
    File.chmod!(secret, 0o400)
    assert {:ok, _} = Susan.Credentials.secret(dir, "DATABASE_URL", 100)
    File.ln_s!(secret, Path.join(dir, "LINKED"))
    assert :error = Susan.Credentials.secret(dir, "LINKED", 100)
  end

  @tag obligation: "susan.push_keys.I5"
  test "WNS keys are issued and sent only for notify.windows.com channels" do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Susan.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    config = Fixtures.config()
    source = :crypto.strong_rand_bytes(32)

    body = %{
      "provider" => "wns",
      "token" => Fixtures.wns_channel(),
      "app_id" => "dev.overalls.mila",
      "environment" => "production",
      "deployment" => "control.example.test"
    }

    assert {201, _} = Keys.issue(JSON.encode!(body), source, config, 5)

    for channel <- [
          "https://wns.notify.windows.com.evil.example/w",
          "https://evil.example/notify.windows.com/w",
          "https://wns.notify.windows.com:8443/w"
        ] do
      assert {400, :rejected, nil} =
               Keys.issue(JSON.encode!(%{body | "token" => channel}), source, config, 5)
    end

    {_, key} = Fixtures.push_key(config, provider: :wns, token: "https://evil.example/w")
    Susan.FakeProvider.reset()

    message = %Susan.Provider{
      push_key: key,
      kind: :needs_input,
      ciphertext: "c",
      collapse_id: "x",
      issued_at: 5
    }

    assert :rejected = Susan.Provider.WNS.deliver(message, config)
    assert Susan.FakeProvider.requests() == []
  end
end
