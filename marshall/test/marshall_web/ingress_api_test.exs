defmodule MarshallWeb.IngressAPITest do
  use MarshallWeb.ConnCase, async: false
  @endpoint MarshallWeb.FleetEndpoint
  import ExUnit.CaptureLog
  alias Marshall.Authorization.SystemActor
  alias Marshall.AudiSocket
  alias Marshall.Ingress
  import Marshall.AudiSocket, only: [reply: 2]

  setup do
    {token, _} = Ingress.Token.issue()

    {:ok, service} =
      Ingress.configure_service(%{name: "dns-api", role: :dns, token: token},
        actor: SystemActor.compute()
      )

    %{token: token, service: service}
  end

  test "key recognition uses the shared decoder and a gateway-only closed response", c do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {token, _} = Ingress.Token.issue()

    {:ok, _} =
      Ingress.configure_service(
        %{name: "ssh-status", role: :gateway, host_id: fixture.vm.host_id, token: token},
        actor: SystemActor.compute()
      )

    blob = <<11::32, "ssh-ed25519", 32::32, 7::256>>
    public = "ssh-ed25519 " <> Base.encode64(blob)
    request = %{version: 1, public_key: public}
    unknown = api(token, request, "ssh-key-status") |> reply(200)
    assert {:ok, :unknown} = OverallsProtocol.SSHOnboarding.decode_status(unknown)
    {:ok, key} = Marshall.SSH.add_key(%{public_key: public}, actor: fixture.owner)

    assert {:ok, :recognized} =
             api(token, request, "ssh-key-status")
             |> reply(200)
             |> OverallsProtocol.SSHOnboarding.decode_status()

    assert {:ok, _} = Marshall.SSH.remove_key(%{id: key.id}, actor: fixture.owner)
    assert api(token, request, "ssh-key-status") |> reply(200) == unknown
    assert api(c.token, request, "ssh-key-status") |> reply(401)
    assert api("invalid", request, "ssh-key-status") |> reply(401)
    assert api(token, Map.put(request, :username, "root"), "ssh-key-status") |> reply(400)
    assert api(token, %{request | version: 2}, "ssh-key-status") |> reply(426)
  end

  # @cc [owner:ghuntley,label:verification;observability] ingress-unavailable-diagnostic-class
  # A pending fleet certificate keeps the uniform unavailable answer while the
  # diagnostic survives authentication redaction with only its closed reason
  # class; the bearer credential never appears in captured output.
  test "uniform unavailable responses record a closed reason class without credentials" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {token, _} = Ingress.Token.issue()

    {:ok, _} =
      Ingress.configure_service(
        %{name: "fleet-pending", role: :gateway, host_id: fixture.vm.host_id, token: token},
        actor: SystemActor.compute()
      )

    logs =
      capture_log([metadata: [:event, :reason]], fn ->
        assert api(token, %{version: 1}, "fleet-certificate") |> reply(503) ==
                 %{"error" => "unavailable"}
      end)

    assert logs =~ "event=audi.control_unavailable"
    assert logs =~ "reason=unavailable"
    refute String.contains?(logs, token)

    assert MarshallWeb.IngressAPI.unavailable_reasons() ==
             Marshall.Mailer.LogFilter.control_reasons()
  end

  test "authenticated transport returns only current service identity", c do
    assert %{"version" => 1, "service" => service} =
             http(c.token, %{version: 1}) |> json_response(200)

    assert service["id"] == c.service.id
    assert service["role"] == "dns"
    refute Map.has_key?(service, "token")
    refute Map.has_key?(service, "token_hash")
    assert {:ok, _} = Ingress.disable_service(%{id: c.service.id}, actor: SystemActor.compute())
    assert http(c.token, %{version: 1}) |> json_response(401) == %{"error" => "unauthorized"}
  end

  test "unknown fields and versions are rejected", c do
    assert http(c.token, %{version: 1, role: "gateway"}) |> json_response(400) == %{
             "error" => "invalid_request"
           }

    assert http(c.token, %{version: 2}) |> json_response(426) == %{
             "error" => "unsupported_version"
           }

    assert http("porsche_gateway_wrong-purpose", %{version: 1}) |> json_response(401) == %{
             "error" => "unauthorized"
           }

    assert http(c.token, %{version: 1}, "private-certificate") |> json_response(400) == %{
             "error" => "invalid_request"
           }
  end

  test "forwarded headers and cookies cannot substitute for actual TLS", c do
    response =
      build_conn()
      |> put_req_header("x-forwarded-proto", "https")
      |> put_req_header("authorization", "Bearer " <> c.token)
      |> put_req_header("content-type", "application/json")
      |> post("/api/audi/v1/identity", Jason.encode!(%{version: 1}))

    assert json_response(response, 403) == %{"error" => "https_required"}
  end

  test "oversized bodies are rejected and credentials stay out of debug diagnostics", c do
    old = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: old) end)

    logs =
      capture_log(fn ->
        assert http(c.token, %{version: 1}) |> json_response(200)

        response =
          %{build_conn() | scheme: :https}
          |> put_req_header("authorization", "Bearer " <> c.token)
          |> put_req_header("content-type", "application/json")
          |> post("https://localhost/api/audi/v1/identity", String.duplicate(" ", 4097))

        assert json_response(response, 413) == %{"error" => "message_too_large"}
      end)

    refute String.contains?(logs, c.token)
  end

  test "SSH routes reject caller-supplied authority fields", c do
    for {route, body} <- [
          {"ssh-open",
           %{version: 1, public_key: "key", label: "vm", host_id: Ash.UUID.generate()}},
          {"ssh-renew", %{version: 1, session_token: "ticket", binding: %{}}},
          {"ssh-close", %{version: 1, session_token: "ticket", user_id: Ash.UUID.generate()}},
          {"dns-proofs", %{version: 1, label: "vm", ttl: 5000}}
        ] do
      assert api(c.token, body, route) |> reply(400) == %{"error" => "invalid_request"}
    end

    assert api(c.token, %{version: 2, session_token: "ticket"}, "ssh-renew")
           |> reply(426) == %{"error" => "unsupported_version"}
  end

  test "gateway peer opening admits a private exact target and reuses no token" do
    {gateway_token, _} = Ingress.Token.issue()
    fixture = Marshall.TerminalFixtures.terminal_fixture()

    {:ok, _service} =
      Ingress.configure_service(
        %{
          name: "gateway-peer-api",
          role: :gateway,
          token: gateway_token,
          host_id: fixture.host.id,
          addresses: ["192.0.2.8"]
        },
        actor: SystemActor.compute()
      )

    {public, _} = :crypto.generate_key(:eddsa, :ed25519)
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, public::binary>>)

    assert {:ok, _} =
             Ingress.publish_host_key(%{token: gateway_token, public_key: key},
               actor: SystemActor.compute()
             )

    {:ok, integration} =
      Marshall.Galileo.configure_integration(
        %{
          name: "peer-api",
          target: nil,
          strip_prefix: nil,
          headers: [],
          peer: true,
          peer_vm_id: fixture.vm.id,
          team_id: nil,
          idempotency_key: Ash.UUID.generate()
        },
        actor: fixture.owner
      )

    [endpoint] = Marshall.Compute.Ledger.read!(Marshall.Ingress.Endpoint, vm_id: fixture.vm.id)

    direct_token =
      Marshall.Galileo.PeerTokens.mint(fixture.vm.id, integration.id, integration.name)

    assert {:ok, _} =
             Ingress.open_peer_web(
               %{
                 service_token: gateway_token,
                 peer_token: direct_token,
                 label: endpoint.label,
                 app_port: 0
               },
               actor: SystemActor.compute()
             )

    peer_token =
      Marshall.Galileo.PeerTokens.mint(fixture.vm.id, integration.id, integration.name)

    request = %{
      version: 1,
      peer_token: peer_token,
      label: endpoint.label,
      app_port: 0
    }

    assert %{"version" => 1, "attestation" => attestation, "grant" => grant} =
             api(gateway_token, request, "galileo-peer") |> reply(200)

    assert attestation == %{
             "purpose" => "galileo-peer",
             "source_vm_id" => fixture.vm.id,
             "name" => integration.name,
             "expires_at" => attestation["expires_at"]
           }

    assert is_integer(attestation["expires_at"])
    assert grant["user_id"] == nil
    assert grant["binding"]["vm_id"] == fixture.vm.id
    assert grant["binding"]["label"] == endpoint.label

    [stream] =
      Marshall.Compute.Ledger.read!(Marshall.Ingress.WebStream,
        id: grant["binding"]["session_id"]
      )

    assert stream.peer_source_vm_id == fixture.vm.id
    assert stream.peer_integration_id == integration.id

    assert api(gateway_token, %{version: 1, stream_token: grant["ticket"]}, "web-renew")
           |> reply(200)

    assert {:ok, _} =
             Marshall.Galileo.remove_integration(%{name: integration.name}, actor: fixture.owner)

    assert {:error, _} =
             Ingress.renew_web(
               %{service_token: gateway_token, stream_token: grant["ticket"]},
               actor: SystemActor.compute()
             )

    for invalid <- [peer_token, "galileo_peer_bogus"] do
      assert api(gateway_token, %{request | peer_token: invalid}, "galileo-peer")
             |> reply(503) == %{"error" => "unavailable"}
    end
  end

  # Gateway and DNS requests run over the control socket (ADR-0142); only
  # identity, the DNS snapshot, host keys and host certificates remain HTTPS
  # routes, for Inception publication and lyra.
  defp api(token, body, route), do: AudiSocket.request(token, route, body)

  defp http(token, body, route \\ "identity") do
    %{build_conn() | scheme: :https}
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("https://localhost/api/audi/v1/" <> route, Jason.encode!(body))
  end
end
