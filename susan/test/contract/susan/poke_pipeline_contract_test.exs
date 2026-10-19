defmodule SusanPokePipelineContractTest do
  use Covenant.Case, component: "susan.poke_pipeline"

  alias Susan.{FakeProvider, Fixtures, Poke}
  alias Susan.Poke.Machine

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Susan.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    FakeProvider.reset()
    config = Fixtures.config()
    {push_key, _} = Fixtures.push_key(config)
    %{config: config, push_key: push_key, install: Fixtures.install()}
  end

  @tag obligation: "susan.poke_pipeline.I1"
  test "sends follow every check and at most two sends happen" do
    {m, :validate} = Machine.start()
    {m, _} = Machine.next(m, :valid)
    {m, _} = Machine.next(m, :authenticated)
    {m, _} = Machine.next(m, :fresh)
    assert {_, {:respond, 429, :rate_limited, 60}} = Machine.next(m, {:limited, :key, 60})
    {m, :claim} = Machine.next(m, :admitted)
    {m, {:send, 1}} = Machine.next(m, :claimed)
    {m, {:send, 2}} = Machine.next(m, {:retry, 1})
    assert {_, {:respond, 503, :unavailable, 2}} = Machine.next(m, {:retry, 2})
    {fresh, :validate} = Machine.start()
    assert {_, {:respond, 503, _, _}} = Machine.next(fresh, :claimed)
  end

  @tag obligation: "susan.poke_pipeline.I2"
  test "bad keys and bad signatures look like malformed requests", ctx do
    {other, _} = Fixtures.install()

    forged = %{
      Fixtures.poke(ctx.push_key, ctx.install)
      | install_key: Base.url_encode64(other, padding: false)
    }

    unknown = Fixtures.poke(String.duplicate("A", 300), ctx.install)
    assert {:respond, 404, :rejected, nil} = Poke.handle(forged, ctx.config)
    assert {:respond, 404, :rejected, nil} = Poke.handle(unknown, ctx.config)
    assert {:respond, 400, :rejected, nil} = Poke.handle(%{unknown | body: "[]"}, ctx.config)
    assert Susan.Audit.Log.read() == []
  end

  @tag obligation: "susan.poke_pipeline.I3"
  test "a retried delivery id is not delivered twice", ctx do
    delivery = Susan.PushKey.uuid()

    for _ <- 1..3,
        do:
          assert(
            {:respond, 204, _, _} =
              Poke.handle(
                Fixtures.poke(ctx.push_key, ctx.install, delivery_id: delivery),
                ctx.config
              )
          )

    assert length(FakeProvider.requests()) == 1
  end

  @tag obligation: "susan.poke_pipeline.I4"
  test "replays and stale pokes are refused before sending", ctx do
    nonce = :crypto.strong_rand_bytes(16)

    assert {:respond, 204, _, _} =
             Poke.handle(Fixtures.poke(ctx.push_key, ctx.install, nonce: nonce), ctx.config)

    assert {:respond, 400, _, _} =
             Poke.handle(Fixtures.poke(ctx.push_key, ctx.install, nonce: nonce), ctx.config)

    now = System.os_time(:second)

    assert {:respond, 400, _, _} =
             Poke.handle(
               Fixtures.poke(ctx.push_key, ctx.install, issued_at: now + 301, now: now),
               ctx.config
             )

    assert length(FakeProvider.requests()) == 1
  end

  @tag obligation: "susan.poke_pipeline.I5"
  test "ten pokes per key then 429", ctx do
    results =
      for _ <- 1..11, do: Poke.handle(Fixtures.poke(ctx.push_key, ctx.install), ctx.config)

    assert Enum.count(results, &match?({:respond, 204, _, _}, &1)) == 10
    assert {:respond, 429, :rate_limited, retry} = List.last(results)
    assert retry > 0
  end

  @tag obligation: "susan.poke_pipeline.I6"
  test "provider payloads carry only ciphertext, collapse id and fixed keys", ctx do
    input = Fixtures.poke(ctx.push_key, ctx.install)
    assert {:respond, 204, _, _} = Poke.handle(input, ctx.config)
    [request] = FakeProvider.requests()
    payload = JSON.decode!(request.body)
    assert Map.keys(payload) |> Enum.sort() == ["aps", "overalls"]
    assert payload["aps"]["mutable-content"] == 1
    assert Map.keys(payload["overalls"]) |> Enum.sort() == ["c", "k", "v"]

    message = %Susan.Provider{
      push_key: %{elem(Fixtures.push_key(ctx.config, provider: :fcm), 1) | token: "t"},
      ciphertext: "c",
      collapse_id: "x",
      kind: :needs_input,
      issued_at: 0
    }

    fcm = Susan.Provider.FCM.payload(message)["message"]
    refute Map.has_key?(fcm, "notification")
    assert fcm["data"]["overalls_c"] == "c"
  end
end
