defmodule Marshall.Control.PorscheBoundRotationPropertyTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures

  alias OverallsProtocol.Control.Client
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.SSH
  alias Marshall.SSH.Session

  @certificate Path.expand("../../fixtures/tls/localhost.pem", __DIR__)
  @key Path.expand("../../fixtures/tls/localhost.key", __DIR__)
  @ca Path.expand("../../fixtures/tls/ca.pem", __DIR__)

  # @cc [owner:ghuntley,label:verification;security] porsche-bound-gateway-rotation
  # Bound old credentials MUST refuse after explicit gateway rotation. A fresh
  # credential MUST serve new sessions without adopting old-generation sessions.
  property "bound Porsche sockets preserve credential and session generation fences" do
    account = user()
    public_key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 12::256>>)
    {:ok, _} = SSH.add_key(%{public_key: public_key}, actor: account)
    base = listener()

    check all(prefix <- integer(0..3), max_runs: 4) do
      name = "rotation-" <> Ash.UUID.generate()
      {token, _} = SSH.Token.issue(:gateway)

      {:ok, configured} =
        SSH.configure_gateway(%{name: name, token: token}, actor: SystemActor.compute())

      {old, old_id} = connected(base, token)
      create = %{"version" => 1, "public_key" => public_key}
      {:ok, issued} = Client.request(old, "porsche.sessions", create)
      assert issued["status"] == "authenticated"
      assert issued["user"]["id"] == account.id
      read = %{"version" => 1, "session_token" => issued["session_token"]}
      expected = Map.delete(issued, "session_token")
      assert Client.request(old, "porsche.session", read) == {:ok, expected}

      for _ <- List.duplicate(:request, prefix) do
        assert Client.request(old, "porsche.session", read) == {:ok, expected}
      end

      {replacement, _} = SSH.Token.issue(:gateway)

      {:ok, rotated} =
        SSH.configure_gateway(%{name: name, token: replacement}, actor: SystemActor.compute())

      assert rotated.id == configured.id
      assert rotated.generation == configured.generation + 1
      assert Client.ready?(old)
      assert Client.request(old, "porsche.session", read) == {:error, "unauthorized"}
      assert Client.request(old, "porsche.sessions", create) == {:error, "unauthorized"}

      assert Enum.map(Ledger.read!(Session, gateway_id: configured.id), & &1.id) ==
               [issued["session_id"]]

      {fresh, fresh_id} = connected(base, replacement)
      assert Client.request(fresh, "porsche.session", read) == {:error, "unauthorized"}
      assert {:ok, new_session} = Client.request(fresh, "porsche.sessions", create)
      assert new_session["status"] == "authenticated"
      assert new_session["user"]["id"] == account.id
      refute new_session["session_id"] == issued["session_id"]
      new_read = %{"version" => 1, "session_token" => new_session["session_token"]}

      assert Client.request(fresh, "porsche.session", new_read) ==
               {:ok, Map.delete(new_session, "session_token")}

      assert Client.request(old, "porsche.session", new_read) == {:error, "unauthorized"}
      :ok = stop_supervised(fresh_id)
      :ok = stop_supervised(old_id)
    end
  end

  @spec connected(String.t(), binary()) :: {pid(), reference()}
  defp connected(base, token) do
    id = make_ref()

    client =
      start_supervised!(
        {Client,
         [
           url: base,
           service: "porsche",
           credential: fn -> {:ok, token} end,
           bind: fn -> %{} end,
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
