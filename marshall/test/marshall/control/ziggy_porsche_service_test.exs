defmodule Marshall.Control.ZiggyPorscheServiceTest do
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures

  alias Marshall.Authorization.SystemActor
  alias Marshall.Control.Services.{Porsche, Ziggy}
  alias Marshall.SSH

  setup do
    fixture = host_fixture()
    {:ok, inference} = Marshall.Inference.Credentials.rotate(fixture.host.id, 3600)
    {gateway, _} = SSH.Token.issue(:gateway)

    {:ok, _} =
      SSH.configure_gateway(%{name: "socket", token: gateway}, actor: SystemActor.compute())

    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 12::256>>)
    ziggy = inference.id <> "." <> inference.secret
    Map.merge(fixture, %{ziggy: ziggy, gateway: gateway, public_key: key, user: user()})
  end

  test "Ziggy binds its host and keeps its error classes", c do
    assert {:ok, %{host_id: host_id} = principal} = Ziggy.authenticate(c.ziggy)
    assert host_id == c.host.id
    assert Ziggy.authenticate(String.duplicate("x", 80)) == :refused

    assert {:ok, ^principal, [{:host, ^host_id}, {:ziggy_work, ^host_id}]} =
             Ziggy.bind(principal, %{"host_id" => host_id})

    assert Ziggy.bind(principal, %{"host_id" => Ecto.UUID.generate()}) == {:close, :refused}

    limits = Marshall.Control.Service.limits(Ziggy)
    assert limits.inbound > 1_100_000 and limits.in_flight == 256

    assert Ziggy.handle_request("ziggy.identity", %{"version" => 2}, principal) ==
             {:ok, %{"host_id" => host_id}}

    assert Ziggy.handle_request("ziggy.identity", %{"version" => 1}, principal) ==
             {:error, "unsupported_version"}

    assert Ziggy.handle_request("ziggy.nothing", %{"version" => 2}, principal) ==
             {:error, "invalid_request"}

    assert Ziggy.handle_request("ziggy.authorize", %{"version" => 2, "x" => 1}, principal) ==
             {:error, "invalid_request"}
  end

  test "Porsche binds its gateway with an empty hello", c do
    assert {:ok, %{gateway_id: id} = principal} = Porsche.authenticate(c.gateway)
    assert Porsche.authenticate("porsche_gateway_" <> String.duplicate("Z", 43)) == :refused
    assert {:ok, ^principal, [{:service, ^id}]} = Porsche.bind(principal, %{})
    assert Porsche.bind(principal, %{"x" => 1}) == {:close, :refused}
    assert Marshall.Control.Service.limits(Porsche).in_flight == 256
    assert Porsche.handle_request("ziggy.identity", %{}, principal) == {:error, "invalid_request"}
  end

  # @cc [owner:ghuntley,label:verification;protocol] control-porsche-transport-equivalence
  # Independent session creations MUST agree on stable status/user fields and
  # each issued session MUST resolve identically through the opposite adapter.
  # Refusals MUST retain the shared request handler's closed error name.
  test "Porsche adapters preserve session meaning and refusal names", c do
    {:ok, _} = SSH.add_key(%{public_key: c.public_key}, actor: c.user)
    {:ok, principal} = Porsche.authenticate(c.gateway)

    cases =
      member_of([
        {"sessions", %{"version" => 1, "public_key" => c.public_key}},
        {"sessions", %{"version" => 1, "public_key" => "invalid"}},
        {"sessions", %{"version" => 2, "public_key" => c.public_key}},
        {"session", %{"version" => 1, "session_token" => "unknown"}},
        {"close", %{"version" => 1, "session_token" => "unknown"}},
        {"commands", %{"version" => 1, "session_token" => "unknown", "command" => "ls"}}
      ])

    check all({route, body} <- cases, max_runs: 24) do
      http = ssh(c.gateway, route, body)
      socket = Porsche.handle_request("porsche." <> route, body, principal)

      case {http.status, socket} do
        {200, {:ok, value}} ->
          document = Jason.decode!(http.resp_body)
          assert Map.keys(value) == Map.keys(document)
          assert Map.take(value, ["status", "user"]) == Map.take(document, ["status", "user"])
          assert value["status"] == "authenticated"
          assert value["user"]["id"] == c.user.id
          assert value["session_id"] != document["session_id"]
          assert value["session_token"] != document["session_token"]

          for issued <- [document, value] do
            status_body = %{"version" => 1, "session_token" => issued["session_token"]}
            status_http = ssh(c.gateway, "session", status_body)
            assert status_http.status == 200

            assert {:ok, status_socket} =
                     Porsche.handle_request("porsche.session", status_body, principal)

            assert status_socket == Jason.decode!(status_http.resp_body)
            assert status_socket == Map.delete(issued, "session_token")
          end

        {_status, {:error, name}} ->
          assert Jason.decode!(http.resp_body) == %{"error" => name}

        other ->
          flunk("transport results differ for #{route}: #{inspect(other)}")
      end
    end
  end

  @spec ssh(binary(), String.t(), map()) :: Plug.Conn.t()
  defp ssh(token, route, body) do
    {status, document} = Marshall.PorscheSocket.request(token, route, body)
    %Plug.Conn{status: status, resp_body: Jason.encode!(document)}
  end
end
