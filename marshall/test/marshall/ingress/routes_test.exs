defmodule Marshall.Ingress.RoutesTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger, VirtualMachine}
  alias Marshall.Ingress
  alias Marshall.Ingress.{FleetCertificate, Route, Token}

  setup do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {token, _} = Token.issue()

    params = %{
      name: "route-" <> Ash.UUID.generate(),
      role: :gateway,
      host_id: fixture.vm.host_id,
      token: token,
      addresses: ["192.0.2.9"]
    }

    {:ok, service} = Ingress.configure_service(params, actor: SystemActor.compute())
    {public, _} = :crypto.generate_key(:eddsa, :ed25519)
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, public::binary>>)

    {:ok, _} =
      Ingress.publish_host_key(%{token: token, public_key: key}, actor: SystemActor.compute())

    expiry = DateTime.add(Ledger.now(), 3600)
    fingerprint = String.duplicate("a", 64)
    Marshall.FleetCertificateFixtures.install!(service, expiry, fingerprint)

    request = %{
      service_token: token,
      service_generation: service.generation,
      vm_id: fixture.vm.id,
      placement_id: fixture.vm.current_placement_id,
      execution_epoch: fixture.vm.execution_epoch,
      generation: fixture.vm.generation,
      certificate_fingerprint: fingerprint,
      certificate_expires_at: expiry
    }

    Map.merge(fixture, %{service: service, params: params, request: request})
  end

  test "reports bind current execution and cap freshness without auditing every refresh", c do
    before = Ledger.now()
    assert {:ok, first} = report(c.request)
    assert DateTime.diff(first.expires_at, before, :millisecond) in 1..5100
    assert {:ok, second} = report(c.request)
    assert first.id == second.id
    assert second.revision == first.revision + 1
    [route] = Ledger.read!(Route, id: first.id)
    assert route.service_id == c.service.id
    assert route.host_id == c.vm.host_id
    assert route.placement_id == c.vm.current_placement_id
    assert route.execution_epoch == c.vm.execution_epoch
    assert [_created] = Ledger.read!(Route.Version, version_source_id: route.id)

    assert {:error, _} =
             report(%{c.request | certificate_fingerprint: String.duplicate("b", 64)})

    assert [_created] = Ledger.read!(Route.Version, version_source_id: route.id)
    assert {:error, _} = Ingress.report_ready_route(c.request, actor: c.owner)
  end

  test "a new route hints the DNS zone but a lease refresh does not", c do
    parent = self()
    handler = "route-dns-hint-" <> Ecto.UUID.generate()

    :telemetry.attach(
      handler,
      [:marshall, :control, :hint],
      fn _, _, %{kind: kind, id: id}, _ -> send(parent, {:hint, kind, id}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    vm_id = c.vm.id
    assert {:ok, _} = report(c.request)
    assert_receive {:hint, :dns_snapshot, ^vm_id}, 1_000
    assert {:ok, _} = report(c.request)
    refute_receive {:hint, :dns_snapshot, _}, 200
  end

  test "certificate validity bounds readiness and expired or malformed metadata is rejected", c do
    expiry = DateTime.add(Ledger.now(), 2)
    assert {:error, _} = report(%{c.request | certificate_expires_at: expiry})

    assert {:error, _} =
             report(%{c.request | certificate_expires_at: DateTime.add(Ledger.now(), -1)})

    for fingerprint <- [
          "",
          String.duplicate("A", 64),
          String.duplicate("a", 63),
          String.duplicate("g", 64)
        ] do
      assert {:error, _} = report(%{c.request | certificate_fingerprint: fingerprint})
    end
  end

  test "wildcard route readiness and current projection require the active gateway installation",
       c do
    previous_zone = Application.get_env(:marshall, :ingress_zone)
    Application.put_env(:marshall, :ingress_zone, "apps.example.test")

    on_exit(fn ->
      restore_env(:ingress_zone, previous_zone)
    end)

    [first] = Ledger.read!(FleetCertificate, zone: "apps.example.test", status: :active)
    assert {:ok, reported} = report(c.request)
    assert {:ok, _} = current(reported.label)

    Ledger.update!(first, :retire, %{})

    Ledger.create!(FleetCertificate, :enqueue, %{generation: 2, zone: "apps.example.test"})
    |> Ledger.update!(:bind_order, %{
      order_url: "https://ca.example.test/order/2",
      finalize_url: "https://ca.example.test/finalize/2",
      authorization_url: "https://ca.example.test/auth/2"
    })
    |> Ledger.update!(:finish_issued, %{
      chain_pem: "new-chain",
      fingerprint: String.duplicate("b", 64),
      expires_at: c.request.certificate_expires_at
    })
    |> Ledger.update!(:activate, %{})

    assert {:error, _} = current(reported.label)
    assert {:error, _} = report(c.request)
  end

  # The 2026-10-17 production failure: after the management host moved zones,
  # each gateway held generation-1 installations for both the retired and the
  # active zone, and the projection compared the active certificate with the
  # retired zone's receipt, so every known-hosts lookup was refused.
  test "current projection uses the active zone's installation when another zone shares the generation",
       c do
    assert {:ok, reported} = report(c.request)

    [installation] =
      Ledger.read!(Marshall.Ingress.FleetCertificateInstallation,
        host_id: c.service.host_id,
        zone: "apps.example.test"
      )

    Ledger.create!(Marshall.Ingress.FleetCertificateInstallation, :record, %{
      host_id: c.service.host_id,
      service_id: c.service.id,
      service_generation: c.service.generation,
      zone: "apps.aaaa-retired.test",
      generation: installation.generation,
      fingerprint: String.duplicate("f", 64)
    })

    # Rewriting the active row places the retired zone's row first in both
    # heap and (host_id, zone, generation) index order.
    Ledger.update!(installation, :rebind_service, %{
      service_generation: installation.service_generation
    })

    assert {:ok, projected} = current(reported.label)
    assert projected.certificate_fingerprint == c.request.certificate_fingerprint
    assert {:ok, _} = report(c.request)
  end

  test "generation changes and stale or stopped execution cannot refresh a report", c do
    assert {:ok, first} = report(c.request)

    {:ok, rotated} =
      Ingress.configure_service(%{c.params | addresses: ["192.0.2.10"]},
        actor: SystemActor.compute()
      )

    assert {:error, _} = report(c.request)
    assert {:error, _} = report(%{c.request | service_generation: rotated.generation})
    assert [%{revision: revision}] = Ledger.read!(Route, id: first.id)
    assert revision == first.revision
  end

  test "fresh running evidence is required on every report", c do
    assert {:ok, _} = report(c.request)
    [host] = Ledger.read!(Host, id: c.vm.host_id)
    Ledger.update!(host, :report, %{reported_at: DateTime.add(Ledger.now(), -60)})
    assert {:error, _} = report(c.request)
    Ledger.update!(host, :report, %{reported_at: Ledger.now()})
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

    Ledger.intent!(vm, %{
      desired_state: :stopped,
      generation: vm.generation + 1
    })

    assert {:error, _} = report(c.request)
  end

  property "mismatched execution reports cannot mutate the accepted route", c do
    {:ok, accepted} = report(c.request)

    check all(
            field <-
              member_of([:placement_id, :execution_epoch, :generation, :service_generation]),
            increment <- integer(1..1000),
            max_runs: 25
          ) do
      value =
        if field == :placement_id,
          do: Ash.UUID.generate(),
          else: Map.fetch!(c.request, field) + increment

      assert {:error, _} = report(Map.put(c.request, field, value))
      assert [%{revision: revision}] = Ledger.read!(Route, id: accepted.id)
      assert revision == accepted.revision
    end
  end

  property "refreshes preserve one route and reject unacknowledged certificate substitutions",
           c do
    check all(
            fingerprints <- list_of(member_of(["a", "b", "c"]), min_length: 1, max_length: 12),
            max_runs: 15
          ) do
      [host] = Ledger.read!(Host, id: c.vm.host_id)
      Ledger.update!(host, :report, %{reported_at: Ledger.now()})
      {:ok, initial} = report(c.request)

      Enum.reduce(fingerprints, initial, fn prefix, previous ->
        request = %{c.request | certificate_fingerprint: String.duplicate(prefix, 64)}

        next =
          if prefix == "a" do
            assert {:ok, next} = report(request)
            assert next.revision == previous.revision + 1
            next
          else
            assert {:error, _} = report(request)
            previous
          end

        assert next.id == initial.id
        assert next.certificate_fingerprint == c.request.certificate_fingerprint
        assert [%{id: id, revision: revision}] = Ledger.read!(Route, vm_id: c.vm.id)
        assert id == initial.id
        assert revision == next.revision
        next
      end)
    end
  end

  property "only completed start or provision history admits readiness and current projection",
           c do
    {:ok, accepted} = report(c.request)

    check all(
            states <-
              list_of(
                tuple(
                  {member_of(["pending", "acknowledged", "completed", "cancelled"]),
                   member_of(["provision", "start", "stop", "delete", "resize"])}
                ),
                min_length: 1,
                max_length: 12
              ),
            max_runs: 15
          ) do
      [host] = Ledger.read!(Host, id: c.vm.host_id)
      Ledger.update!(host, :report, %{reported_at: Ledger.now()})

      for {status, kind} <- states do
        # Only this sandbox fixture's operation history is changed. Keep the
        # execution binding fixed so status/kind alone decide admissibility.
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "UPDATE compute_operations SET status=$1, kind=$2 WHERE vm_id=$3",
          [status, kind, Ecto.UUID.dump!(c.vm.id)],
          log: false
        )

        eligible? = status == "completed" and kind in ["provision", "start"]
        assert match?({:ok, _}, report(c.request)) == eligible?
        assert match?({:ok, _}, current(accepted.label)) == eligible?
      end
    end
  end

  defp report(request), do: Ingress.report_ready_route(request, actor: SystemActor.compute())

  test "current projection supplies only fresh gateway data and does not mutate the report", c do
    [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)
    assert {:error, _} = current(endpoint.label)
    {:ok, reported} = report(c.request)
    assert {:ok, route} = current(reported.label)
    assert route.id == reported.id
    assert route.addresses == ["192.0.2.9"]
    assert String.starts_with?(route.ssh_host_key, "ssh-ed25519 ")
    assert route.ttl in 1..5000
    refute Map.has_key?(route, :service_token)
    assert route.certificate_fingerprint == c.request.certificate_fingerprint
    assert [%{revision: revision}] = Ledger.read!(Route, id: reported.id)
    assert revision == reported.revision
    assert {:error, _} = Ingress.current_route(%{label: reported.label}, actor: c.owner)
    assert {:error, _} = current("missing-0123456789abcdef0123456789abcdef")
    assert {:error, _} = current("invalid")
  end

  test "stored readiness cannot outlive gateway rotation or disablement", c do
    {:ok, reported} = report(c.request)
    assert {:ok, previous} = current(reported.label)

    {:ok, _} =
      Ingress.configure_service(%{c.params | addresses: ["192.0.2.10"]},
        actor: SystemActor.compute()
      )

    assert {:error, _} = current(reported.label)

    assert {:ok, _} =
             Ingress.publish_host_key(%{token: c.params.token, public_key: previous.ssh_host_key},
               actor: SystemActor.compute()
             )

    assert {:error, _} = current(reported.label)
    {:ok, _} = Ingress.disable_service(%{id: c.service.id}, actor: SystemActor.compute())
    assert {:error, _} = current(reported.label)
  end

  test "current projection rejects report expiry, stale host evidence and changed execution", c do
    {:ok, reported} = report(c.request)
    [route] = Ledger.read!(Route, id: reported.id)
    Ledger.update!(route, :refresh, %{expires_at: DateTime.add(Ledger.now(), -1), revision: 2})
    assert {:error, _} = current(reported.label)
    assert {:ok, _} = report(c.request)
    [host] = Ledger.read!(Host, id: c.vm.host_id)
    Ledger.update!(host, :report, %{reported_at: DateTime.add(Ledger.now(), -60)})
    assert {:error, _} = current(reported.label)
    Ledger.update!(host, :report, %{reported_at: Ledger.now()})
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

    Ledger.intent!(vm, %{
      generation: vm.generation + 1,
      desired_state: :stopped
    })

    assert {:error, _} = current(reported.label)
  end

  defp current(label), do: Ingress.current_route(%{label: label}, actor: SystemActor.compute())

  test "public known-hosts lookup exposes only a live key and never caches it", c do
    old = Application.get_env(:marshall, :ingress_zone)
    Application.put_env(:marshall, :ingress_zone, "apps.example.test")

    on_exit(fn ->
      if old,
        do: Application.put_env(:marshall, :ingress_zone, old),
        else: Application.delete_env(:marshall, :ingress_zone)
    end)

    [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)
    path = "/api/audi/v1/known-hosts/" <> endpoint.label
    assert lookup("https://control.test" <> path).status == 404
    {:ok, _} = report(c.request)
    {:ok, route} = current(endpoint.label)
    response = lookup("https://control.test" <> path)
    assert response.status == 200

    assert response.resp_body ==
             endpoint.label <> ".apps.example.test " <> route.ssh_host_key <> "\n"

    assert Plug.Conn.get_resp_header(response, "cache-control") == ["no-store"]

    for {method, url} <- [
          {:get, "http://control.test" <> path},
          {:post, "https://control.test" <> path},
          {:get, "https://control.test" <> path <> "?key=attacker"}
        ] do
      denied = lookup(url, method)
      assert denied.status == 404
      refute String.contains?(denied.resp_body, "ssh-ed25519")
    end

    {:ok, _} = Ingress.disable_service(%{id: c.service.id}, actor: SystemActor.compute())
    assert lookup("https://control.test" <> path).status == 404
  end

  defp lookup(url, method \\ :get) do
    Plug.Test.conn(method, url)
    |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
    |> MarshallWeb.IngressAPI.call([])
  end

  @spec restore_env(atom(), term()) :: :ok
  defp restore_env(key, nil), do: Application.delete_env(:marshall, key)
  defp restore_env(key, value), do: Application.put_env(:marshall, key, value)
end
