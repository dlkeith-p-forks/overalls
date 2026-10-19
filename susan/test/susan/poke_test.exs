defmodule Susan.PokeTest do
  use Susan.DataCase, async: false

  alias Susan.{FakeProvider, Poke}
  alias Susan.Audit.AuditEntry
  alias Susan.Relay.{InstallIdentity, KeyDenial}

  setup do
    config = Fixtures.config()
    {push_key, key} = Fixtures.push_key(config)
    %{config: config, push_key: push_key, key: key, install: Fixtures.install()}
  end

  defp actions,
    do:
      AuditEntry |> Ash.Query.sort(seq: :asc) |> Ash.read!() |> Enum.map(&{&1.action, &1.reason})

  test "a valid poke is sent once to APNs with fixed loc-keys and only the ciphertext", ctx do
    input = Fixtures.poke(ctx.push_key, ctx.install, collapse_id: "thread-9")
    assert {:respond, 204, :empty, nil} = Poke.handle(input, ctx.config)

    assert [request] = FakeProvider.requests()
    assert request.url == "https://api.push.apple.com/3/device/" <> ctx.key.token
    headers = Map.new(request.headers)
    assert headers["apns-topic"] == "dev.overalls.mila"
    assert headers["apns-collapse-id"] == Fixtures.collapse_id("thread-9")
    assert headers["apns-push-type"] == "alert"
    assert "bearer " <> _ = headers["authorization"]
    payload = JSON.decode!(request.body)
    ciphertext = JSON.decode!(input.body)["ciphertext"]
    assert payload["aps"]["mutable-content"] == 1

    assert payload["aps"]["alert"] == %{
             "title-loc-key" => "MILA_PUSH_NEEDS_INPUT_TITLE",
             "loc-key" => "MILA_PUSH_NEEDS_INPUT_BODY"
           }

    assert payload["overalls"] == %{"v" => 1, "k" => "needs_input", "c" => ciphertext}
    refute request.body =~ Fixtures.deployment()

    assert [{:install_first_seen, nil}, {:poke_accepted, nil}, {:provider_sent, nil}] = actions()

    assert %{state: :trusted} =
             InstallIdentity.by_fingerprint!(Susan.Poke.Request.fingerprint(elem(ctx.install, 0)))
  end

  test "an FCM key sends a data-only message after one OAuth exchange", ctx do
    {push_key, key} = Fixtures.push_key(ctx.config, provider: :fcm)

    assert {:respond, 204, :empty, nil} =
             Poke.handle(Fixtures.poke(push_key, ctx.install), ctx.config)

    assert {:respond, 204, :empty, nil} =
             Poke.handle(Fixtures.poke(push_key, ctx.install), ctx.config)

    assert [oauth, send, send2] = FakeProvider.requests()
    assert oauth.url == "https://oauth2.googleapis.com/token"
    assert oauth.body =~ "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer"
    assert send.url == "https://fcm.googleapis.com/v1/projects/overalls-test/messages:send"
    assert send2.url == send.url
    message = JSON.decode!(send.body)["message"]
    assert message["token"] == key.token
    refute Map.has_key?(message, "notification")
    assert message["data"]["overalls_k"] == "needs_input"
    assert message["android"]["collapse_key"] == Fixtures.collapse_id("thread-1")
  end

  test "a retried delivery id is answered without a second provider send", ctx do
    delivery = Susan.PushKey.uuid()

    assert {:respond, 204, _, _} =
             Poke.handle(
               Fixtures.poke(ctx.push_key, ctx.install, delivery_id: delivery),
               ctx.config
             )

    assert {:respond, 204, _, _} =
             Poke.handle(
               Fixtures.poke(ctx.push_key, ctx.install, delivery_id: delivery),
               ctx.config
             )

    assert length(FakeProvider.requests()) == 1
  end

  test "provider 503 twice answers 503 after exactly two sends; the next retry succeeds once",
       ctx do
    FakeProvider.script([
      {"https://api.push.apple.com", 503, [{"retry-after", "7"}], ""},
      {"https://api.push.apple.com", 503, [{"retry-after", "7"}], ""}
    ])

    delivery = Susan.PushKey.uuid()
    input = fn -> Fixtures.poke(ctx.push_key, ctx.install, delivery_id: delivery) end
    assert {:respond, 503, :unavailable, 7} = Poke.handle(input.(), ctx.config)
    assert length(FakeProvider.requests()) == 2
    assert {:respond, 204, :empty, nil} = Poke.handle(input.(), ctx.config)
    assert length(FakeProvider.requests()) == 3
    assert {:respond, 204, :empty, nil} = Poke.handle(input.(), ctx.config)
    assert length(FakeProvider.requests()) == 3
  end

  test "one transient failure is retried within the request", ctx do
    FakeProvider.script([{"https://api.push.apple.com", :transport}])

    assert {:respond, 204, _, _} =
             Poke.handle(Fixtures.poke(ctx.push_key, ctx.install), ctx.config)

    assert length(FakeProvider.requests()) == 2
  end

  test "an unregistered token answers 410 and is negative-cached", ctx do
    FakeProvider.script([{"https://api.push.apple.com", 410, [], ~s({"reason":"Unregistered"})}])

    assert {:respond, 410, :unregistered, nil} =
             Poke.handle(Fixtures.poke(ctx.push_key, ctx.install), ctx.config)

    assert {:respond, 410, :unregistered, nil} =
             Poke.handle(Fixtures.poke(ctx.push_key, ctx.install), ctx.config)

    assert length(FakeProvider.requests()) == 1
    assert {:provider_unregistered, nil} in actions()
    assert {:poke_rejected, :unregistered} in actions()
  end

  test "replayed nonces and stale times are refused", ctx do
    nonce = :crypto.strong_rand_bytes(16)

    assert {:respond, 204, _, _} =
             Poke.handle(Fixtures.poke(ctx.push_key, ctx.install, nonce: nonce), ctx.config)

    assert {:respond, 400, :rejected, nil} =
             Poke.handle(Fixtures.poke(ctx.push_key, ctx.install, nonce: nonce), ctx.config)

    now = System.os_time(:second)

    assert {:respond, 400, :rejected, nil} =
             Poke.handle(
               Fixtures.poke(ctx.push_key, ctx.install, issued_at: now - 301, now: now),
               ctx.config
             )

    assert length(FakeProvider.requests()) == 1
    assert {:poke_rejected, :replayed} in actions() and {:poke_rejected, :stale} in actions()
  end

  test "unauthenticated pokes answer 404 like malformed ones and write nothing", ctx do
    {other_public, _} = Fixtures.install()

    forged = %{
      Fixtures.poke(ctx.push_key, ctx.install)
      | install_key: Base.url_encode64(other_public, padding: false)
    }

    assert {:respond, 404, :rejected, nil} = Poke.handle(forged, ctx.config)

    unknown = Fixtures.poke(String.duplicate("A", 300), ctx.install)
    assert {:respond, 404, :rejected, nil} = Poke.handle(unknown, ctx.config)
    assert {:respond, 400, :rejected, nil} = Poke.handle(%{unknown | body: "{}"}, ctx.config)

    assert actions() == []
    assert Ash.read!(InstallIdentity) == []
    assert FakeProvider.requests() == []
  end

  test "deployment mismatch, deny-listed keys and blocked installs are refused before sending",
       ctx do
    assert {:respond, 404, _, _} =
             Poke.handle(
               Fixtures.poke(ctx.push_key, ctx.install, deployment: "other.example.test"),
               ctx.config
             )

    {:ok, _} = KeyDenial.deny(ctx.key.key_id, :abuse)

    assert {:respond, 404, _, _} =
             Poke.handle(Fixtures.poke(ctx.push_key, ctx.install), ctx.config)

    {push_key, _} = Fixtures.push_key(ctx.config)

    {:ok, identity} =
      InstallIdentity.first_seen(Susan.Poke.Request.fingerprint(elem(ctx.install, 0)))

    {:ok, _} = InstallIdentity.block(identity)
    assert {:respond, 404, _, _} = Poke.handle(Fixtures.poke(push_key, ctx.install), ctx.config)

    assert FakeProvider.requests() == []
    assert {:poke_rejected, :deployment_mismatch} in actions()
    assert {:poke_rejected, :denylisted} in actions()
    assert {:poke_rejected, :install_blocked} in actions()
  end

  test "the per-key bucket admits ten then answers 429 with Retry-After, audited once", ctx do
    results =
      for _ <- 1..12, do: Poke.handle(Fixtures.poke(ctx.push_key, ctx.install), ctx.config)

    assert Enum.count(results, &match?({:respond, 204, _, _}, &1)) == 10

    assert [{:respond, 429, :rate_limited, 60}, {:respond, 429, :rate_limited, 60}] =
             Enum.drop(results, 10)

    assert Enum.count(actions(), &(&1 == {:rate_limited, :key})) == 1
    assert length(FakeProvider.requests()) == 10
  end

  test "exhausting the install bucket moves the identity to rate_limited", ctx do
    limits = Map.put(Susan.RateLimiter.defaults(), :install, %{burst: 2, per_hour: 1})
    config = %{ctx.config | limits: limits}
    install = Fixtures.install()
    fingerprint = Susan.Poke.Request.fingerprint(elem(install, 0))
    {push_key, _} = Fixtures.push_key(config)

    for _ <- 1..2,
        do: assert({:respond, 204, _, _} = Poke.handle(Fixtures.poke(push_key, install), config))

    assert {:respond, 429, :rate_limited, _} =
             Poke.handle(Fixtures.poke(push_key, install), config)

    assert %{state: :rate_limited} = InstallIdentity.by_fingerprint!(fingerprint)
    assert {:rate_limited, :install} in actions()
  end
end
