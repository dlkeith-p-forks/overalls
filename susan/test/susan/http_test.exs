defmodule Susan.HTTPTest do
  use Susan.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  setup do
    %{config: Fixtures.config()}
  end

  defp post(path, body, config, headers \\ []) do
    conn(:post, path, body)
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    end)
    |> Susan.HTTP.call(config)
  end

  test "health reports database reachability", ctx do
    conn = conn(:get, "/healthz") |> Susan.HTTP.call(ctx.config)
    assert conn.status == 200 and conn.resp_body == ~s({"status":"ok"})
  end

  test "keys then poke round-trip over HTTP", ctx do
    request = %{
      "provider" => "apns",
      "token" => Fixtures.apns_token(),
      "app_id" => "dev.overalls.mila",
      "environment" => "production",
      "deployment" => "control.example.test"
    }

    issued = post("/api/push/v1/keys", JSON.encode!(request), ctx.config)
    assert issued.status == 201
    assert get_resp_header(issued, "cache-control") == ["no-store"]
    %{"push_key" => push_key} = JSON.decode!(issued.resp_body)

    poke = Fixtures.poke(push_key, Fixtures.install())

    conn =
      post("/api/push/v1/poke", poke.body, ctx.config, [
        {"overalls-install-key", poke.install_key},
        {"overalls-install-signature", poke.signature}
      ])

    assert conn.status == 204 and conn.resp_body == ""
    assert length(Susan.FakeProvider.requests()) == 1
  end

  test "malformed, oversized and unknown requests share one body", ctx do
    poke = Fixtures.poke(String.duplicate("A", 200), Fixtures.install())

    headers = [
      {"overalls-install-key", poke.install_key},
      {"overalls-install-signature", poke.signature}
    ]

    unknown = post("/api/push/v1/poke", poke.body, ctx.config, headers)
    malformed = post("/api/push/v1/poke", "{}", ctx.config, headers)
    oversized = post("/api/push/v1/poke", String.duplicate("a", 1025), ctx.config, headers)
    route = post("/api/push/v1/other", "{}", ctx.config)

    assert {unknown.status, malformed.status, oversized.status, route.status} ==
             {404, 400, 400, 404}

    assert Enum.uniq(Enum.map([unknown, malformed, oversized, route], & &1.resp_body)) == [
             ~s({"error":"rejected"})
           ]

    text =
      conn(:post, "/api/push/v1/poke", poke.body)
      |> put_req_header("content-type", "text/plain")
      |> Susan.HTTP.call(ctx.config)

    assert text.status == 400
  end

  test "trusted proxies supply the client address; others cannot" do
    trusted = [{127, 0, 0, 1}]

    assert Susan.SourceAddress.client({127, 0, 0, 1}, ["198.51.100.4, 203.0.113.9"], trusted) ==
             {203, 0, 113, 9}

    assert Susan.SourceAddress.client({192, 0, 2, 1}, ["203.0.113.9"], trusted) == {192, 0, 2, 1}
    assert Susan.SourceAddress.client({127, 0, 0, 1}, ["garbage"], trusted) == {127, 0, 0, 1}
    assert byte_size(Susan.SourceAddress.digest({203, 0, 113, 9})) == 32
  end
end
