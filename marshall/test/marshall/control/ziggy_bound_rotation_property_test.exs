defmodule Marshall.Control.ZiggyBoundRotationPropertyTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures

  alias OverallsProtocol.Control.Client
  alias Marshall.Inference.Credentials

  @certificate Path.expand("../../fixtures/tls/localhost.pem", __DIR__)
  @key Path.expand("../../fixtures/tls/localhost.key", __DIR__)
  @ca Path.expand("../../fixtures/tls/ca.pem", __DIR__)

  # @cc [owner:ghuntley,label:verification;security] ziggy-bound-credential-rotation
  # A bound socket MUST refuse fresh identity requests after its credential
  # rotates. A fresh credential MUST bind and serve the same host; the old
  # connection's prior welcome MUST NOT substitute for current authority.
  property "bound Ziggy sockets recheck rotated credentials on every request" do
    fixture = host_fixture()
    base = listener()

    check all(prefix <- integer(0..3), max_runs: 4) do
      {:ok, first} = Credentials.rotate(fixture.host.id, 3600)
      {old, old_id} = connected(base, first.id <> "." <> first.secret, fixture.host.id)
      body = %{"version" => 2}
      expected = %{"host_id" => fixture.host.id}

      assert Client.request(old, "ziggy.identity", body) == {:ok, expected}

      for _ <- List.duplicate(:request, prefix) do
        assert Client.request(old, "ziggy.identity", body) == {:ok, expected}
      end

      {:ok, replacement} = Credentials.rotate(fixture.host.id, 3600)
      assert Client.ready?(old)
      assert Client.request(old, "ziggy.identity", body) == {:error, "unauthorized"}
      assert Client.request(old, "ziggy.identity", body) == {:error, "unauthorized"}

      {fresh, fresh_id} =
        connected(base, replacement.id <> "." <> replacement.secret, fixture.host.id)

      assert Client.request(fresh, "ziggy.identity", body) == {:ok, expected}
      assert Client.request(old, "ziggy.identity", body) == {:error, "unauthorized"}
      :ok = stop_supervised(fresh_id)
      :ok = stop_supervised(old_id)
    end
  end

  @spec connected(String.t(), binary(), String.t()) :: {pid(), reference()}
  defp connected(base, token, host_id) do
    id = make_ref()

    client =
      start_supervised!(
        {Client,
         [
           url: base,
           service: "ziggy",
           credential: fn -> {:ok, token} end,
           bind: fn -> %{"host_id" => host_id} end,
           cacertfile: @ca,
           owner: self()
         ]},
        id: id
      )

    assert_receive {:control, ^client, {:connected, _welcome}}, 5_000
    assert Client.ready?(client)
    {client, id}
  end

  @spec listener() :: String.t()
  defp listener do
    server =
      start_supervised!(
        {Bandit,
         [
           plug: MarshallWeb.ControlAPI,
           scheme: :https,
           ip: {127, 0, 0, 1},
           port: 0,
           certfile: @certificate,
           keyfile: @key,
           startup_log: false
         ]},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    "https://127.0.0.1:#{port}"
  end
end
