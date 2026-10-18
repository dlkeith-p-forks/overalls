defmodule Marshall.Control.AudiServiceTest do
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen
  @endpoint MarshallWeb.FleetEndpoint
  import ExUnit.CaptureLog

  alias Marshall.Authorization.SystemActor
  alias Marshall.Control.Services.Audi
  alias Marshall.Ingress

  setup do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {gateway, _} = Ingress.Token.issue()
    {dns, _} = Ingress.Token.issue()

    {:ok, service} =
      Ingress.configure_service(
        %{name: "socket-gateway", role: :gateway, host_id: fixture.vm.host_id, token: gateway},
        actor: SystemActor.compute()
      )

    {:ok, _} =
      Ingress.configure_service(%{name: "socket-dns", role: :dns, token: dns},
        actor: SystemActor.compute()
      )

    %{
      gateway: gateway,
      dns: dns,
      service: service,
      host_id: fixture.vm.host_id,
      vm_id: fixture.vm.id
    }
  end

  test "authentication and bind hold the credential's role and host", c do
    assert {:ok, principal} = Audi.authenticate(c.gateway)
    assert %{service_id: id, role: :gateway, host_id: host_id} = principal
    assert id == c.service.id and host_id == c.host_id
    assert Audi.authenticate("audi_service_" <> String.duplicate("B", 43)) == :refused
    assert Audi.authenticate("short") == :refused

    bind = %{"role" => "gateway", "host_id" => c.host_id}

    assert {:ok, ^principal,
            [
              {:service, ^id},
              {:gateway_catalog, ^host_id},
              {:user, :all},
              {:vm, :all},
              {:fleet_certificate, :all}
            ]} =
             Audi.bind(principal, bind)

    assert Audi.bind(principal, %{bind | "role" => "dns"}) == {:close, :refused}
    assert Audi.bind(principal, %{bind | "host_id" => Ecto.UUID.generate()}) == {:close, :refused}
    assert Audi.bind(principal, Map.put(bind, "extra", 1)) == {:close, :refused}

    {:ok, dns} = Audi.authenticate(c.dns)
    dns_id = dns.service_id

    assert {:ok, _, [{:service, ^dns_id}, {:dns_snapshot, :all}]} =
             Audi.bind(dns, %{"role" => "dns", "host_id" => nil})

    assert Audi.limits() == %{frame: 8_389_632, in_flight: 64}
  end

  test "host certificates and unknown ops stay off the socket", c do
    {:ok, principal} = Audi.authenticate(c.gateway)
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 7::256>>)

    assert Audi.handle_request(
             "audi.host_certificate",
             %{"version" => 1, "public_key" => key},
             principal
           ) == {:error, "invalid_request"}

    assert Audi.handle_request("galileo.identity", %{}, principal) == {:error, "invalid_request"}
  end

  test "an unavailable answer records only its closed reason class", c do
    {:ok, principal} = Audi.authenticate(c.gateway)

    logs =
      capture_log([metadata: [:event, :reason]], fn ->
        assert Audi.handle_request("audi.fleet_certificate", %{"version" => 1}, principal) ==
                 {:error, "unavailable"}
      end)

    assert logs =~ "event=audi.control_unavailable"
    assert logs =~ "reason=unavailable"
    refute logs =~ c.gateway
  end

  # @cc [owner:ghuntley,label:verification;protocol] control-audi-transport-equivalence
  # For the same credential, route and body, the control socket MUST answer
  # with the remaining HTTPS route's class (identity and DNS snapshots, kept
  # for Inception publication): the same document on success, and the same
  # denial class (unauthorized, forbidden, named error, unavailable) otherwise.
  test "the socket and the HTTPS routes answer every request with the same class", c do
    cases =
      member_of([
        {"identity", %{}},
        {"identity", %{"role" => "gateway"}},
        {"dns-snapshot", %{"zone" => "apps.example.test"}},
        {"dns-snapshot", %{"zone" => "apps.example.test", "extra" => 1}}
      ])

    Hegel.check(
      fn ->
        route_body = draw("route_body", cases)
        credential = draw("credential", member_of([:gateway, :dns]))
        version = draw("version", member_of([1, 1, 1, 2]))
        {route, body} = route_body
        token = Map.fetch!(c, credential)
        document = Map.put(body, "version", version)
        http = api(token, document, route)
        {:ok, principal} = Audi.authenticate(token)

        socket =
          Audi.handle_request("audi." <> String.replace(route, "-", "_"), document, principal)

        case {http.status, socket} do
          # A snapshot's revision advances with every read; nothing else may differ.
          {200, {:ok, value}} ->
            assert Map.delete(value, "revision") ==
                     Map.delete(Jason.decode!(http.resp_body), "revision")

          {400, {:error, "invalid_request"}} ->
            :ok

          {401, {:error, name}} ->
            assert name in ["unauthorized", "authentication_required"]

          {403, {:error, "forbidden"}} ->
            :ok

          {409, {:error, "host_key_conflict"}} ->
            :ok

          {426, {:error, "unsupported_version"}} ->
            :ok

          {429, {:error, name}} ->
            assert name in ["capacity", "session_limit"]

          {503, {:error, "unavailable"}} ->
            :ok

          other ->
            flunk("transport classes differ for #{route}: #{inspect(other)}")
        end
      end,
      test_cases: 100
    )
  end

  @spec api(binary(), map(), String.t()) :: Plug.Conn.t()
  defp api(token, body, route) do
    %{build_conn() | scheme: :https}
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("https://localhost/api/audi/v1/" <> route, Jason.encode!(body))
  end

  test "catalog hints resolve the VM's current host", c do
    [vm] = Marshall.Compute.Ledger.read!(Marshall.Compute.VirtualMachine, id: c.vm_id)
    assert Marshall.Control.Hints.Hosts.of_vm(vm) == c.host_id
    assert Marshall.Control.Hints.Hosts.of_vm_id(%{vm_id: vm.id}) == c.host_id
    assert Marshall.Control.Hints.Hosts.of_vm_id(%{vm_id: Ecto.UUID.generate()}) == nil
    assert Marshall.Control.Hints.Hosts.of_vm(%{current_placement_id: nil}) == nil
  end
end
