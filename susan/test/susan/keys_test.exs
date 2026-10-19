defmodule Susan.KeysTest do
  use Susan.DataCase, async: false

  alias Susan.{Keys, PushKey}
  alias Susan.Relay.UnregisteredToken

  setup do
    %{config: Fixtures.config(), source: :crypto.strong_rand_bytes(32)}
  end

  defp body(overrides \\ %{}) do
    %{
      "provider" => "apns",
      "token" => Fixtures.apns_token(),
      "app_id" => "dev.overalls.mila",
      "environment" => "development",
      "deployment" => "control.example.test"
    }
    |> Map.merge(overrides)
  end

  test "issues a sealed key that binds the request", ctx do
    request = body()
    now = System.os_time(:second)
    assert {201, response} = Keys.issue(JSON.encode!(request), ctx.source, ctx.config, now)
    assert {:ok, key} = PushKey.open(ctx.config.keyring, response["push_key"], now)
    assert key.key_id == response["key_id"] and key.token == request["token"]
    assert key.environment == :sandbox and key.deployment == "control.example.test"
    assert {:ok, expires, 0} = DateTime.from_iso8601(response["expires_at"])
    assert DateTime.to_unix(expires) == now + 90 * 86_400
  end

  test "refuses unknown fields, foreign apps, malformed tokens and FCM sandbox", ctx do
    now = System.os_time(:second)

    for request <- [
          Map.put(body(), "label", "phone"),
          body(%{"app_id" => "com.example.other"}),
          body(%{"token" => "not-hex"}),
          body(%{"provider" => "fcm", "token" => Fixtures.fcm_token()}),
          body(%{"deployment" => "localhost"}),
          body(%{"provider" => "webpush"})
        ] do
      assert {400, :rejected, nil} =
               Keys.issue(JSON.encode!(request), ctx.source, ctx.config, now)
    end

    assert {400, :rejected, nil} =
             Keys.issue(String.duplicate("x", 1025), ctx.source, ctx.config, now)
  end

  test "refuses tokens the provider reported unregistered", ctx do
    request = body()
    {_, key} = Fixtures.push_key(ctx.config, token: request["token"])
    {:ok, _} = UnregisteredToken.record(Susan.Poke.token_digest(ctx.config, key), :apns)

    assert {410, :unregistered, nil} =
             Keys.issue(JSON.encode!(request), ctx.source, ctx.config, 0)
  end

  test "issuance is rate limited per source", ctx do
    results = for _ <- 1..11, do: Keys.issue(JSON.encode!(body()), ctx.source, ctx.config, 0)
    assert Enum.count(results, &match?({201, _}, &1)) == 10
    assert {429, :rate_limited, 60} = List.last(results)
  end
end
