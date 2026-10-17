defmodule Marshall.Ingress.AccessTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger}
  alias Marshall.Ingress
  alias Marshall.Ingress.Token

  @tag profile: :customer
  test "public customer endpoint cannot authorize anonymous web or browser login", c do
    [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)
    Ledger.update!(endpoint, :change_policy, %{visibility: :public, policy_revision: 2})

    for port <- [0, 3000, 9999] do
      request = %{service_token: c.request.service_token, label: endpoint.label, app_port: port}
      assert {:error, _} = Ingress.open_web(request, actor: SystemActor.compute())

      assert {:error, _} =
               Ingress.begin_web_login(Map.put(request, :state_digest, String.duplicate("a", 64)),
                 actor: SystemActor.compute()
               )
    end

    assert [] = Ledger.read!(Marshall.Ingress.WebStream, vm_id: c.vm.id)
    assert [] = Ledger.read!(Marshall.Ingress.WebLogin, vm_id: c.vm.id)
    {ticket, hash} = Token.issue(:web_stream)

    Ledger.create!(Marshall.Ingress.WebStream, :record, %{
      token_hash: hash,
      service_id: c.service.id,
      service_generation: c.service.generation,
      vm_id: c.vm.id,
      host_id: c.vm.host_id,
      placement_id: c.vm.current_placement_id,
      execution_epoch: c.vm.execution_epoch,
      generation: c.vm.generation,
      label: endpoint.label,
      app_port: 0,
      port: 80,
      policy_revision: 2,
      expires_at: DateTime.add(Ledger.now(), 5)
    })

    assert {:error, _} =
             Ingress.renew_web(%{service_token: c.request.service_token, stream_token: ticket},
               actor: SystemActor.compute()
             )
  end

  setup context do
    fixture =
      Marshall.TerminalFixtures.terminal_fixture(%{
        profile: Map.get(context, :profile, :standard)
      })

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

    request = %{
      service_token: token,
      service_generation: service.generation,
      vm_id: fixture.vm.id,
      placement_id: fixture.vm.current_placement_id,
      execution_epoch: fixture.vm.execution_epoch,
      generation: fixture.vm.generation,
      certificate_fingerprint: String.duplicate("a", 64),
      certificate_expires_at: DateTime.add(Ledger.now(), 3600)
    }

    Map.merge(fixture, %{service: service, params: params, request: request})
  end

  # @cc [owner:ghuntley,label:verification;recovery] web-renewal-across-lilly-restart
  # Web renewal MUST be inconclusive while Lilly reconnects, succeed with the
  # unchanged binding once the new session reports, and stay conclusive for a
  # newer generation or stop even while the host is reconnecting.
  test "web renewal across a Lilly restart is inconclusive, then keeps the binding", c do
    [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)

    assert {:ok, _} =
             Ingress.configure_endpoint(
               %{
                 vm_id: c.vm.id,
                 expected_revision: endpoint.policy_revision,
                 primary_port: 8080,
                 visibility: :public
               },
               actor: c.owner
             )

    request = %{service_token: c.request.service_token, label: endpoint.label, app_port: 0}
    assert {:ok, opened} = Ingress.open_web(request, actor: SystemActor.compute())
    token = c.request.service_token
    renew = %{"version" => 1, "stream_token" => opened.ticket}
    [host] = Ledger.read!(Host, id: c.vm.host_id)
    assert {:ok, :ok} = Marshall.Compute.HostReports.disconnect(host.id, host.connection_epoch)

    assert {:error, :temporarily_unavailable} =
             Marshall.Ingress.ControlRequests.handle("web-renew", token, renew)

    assert {:error, _} = Ingress.open_web(request, actor: SystemActor.compute())
    [host] = Ledger.read!(Host, id: c.vm.host_id)

    Ledger.update!(host, :connect, %{
      connection_session_id: Ash.UUID.generate(),
      connection_epoch: host.connection_epoch + 1,
      report_sequence: 0,
      reported_at: nil
    })

    assert {:error, :temporarily_unavailable} =
             Marshall.Ingress.ControlRequests.handle("web-renew", token, renew)

    [host] = Ledger.read!(Host, id: c.vm.host_id)
    Ledger.update!(host, :report, %{reported_at: Ledger.now()})

    assert {:ok, %{grant: renewed}} =
             Marshall.Ingress.ControlRequests.handle("web-renew", token, renew)

    assert renewed.binding == opened.binding

    [host] = Ledger.read!(Host, id: c.vm.host_id)
    assert {:ok, :ok} = Marshall.Compute.HostReports.disconnect(host.id, host.connection_epoch)
    [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: c.vm.id)
    Ledger.intent!(vm, %{desired_state: :stopped, generation: vm.generation + 1})

    assert {:error, :unauthorized} =
             Marshall.Ingress.ControlRequests.handle("web-renew", token, renew)
  end

  @tag :hegel
  test "public primary streams cannot survive policy changes or authorize alternate ports", c do
    check all(port <- filter(integer(3000..9999), &(&1 != 4444)), max_runs: 8) do
      [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)

      assert {:ok, public} =
               Ingress.configure_endpoint(
                 %{
                   vm_id: c.vm.id,
                   expected_revision: endpoint.policy_revision,
                   primary_port: port,
                   visibility: :public
                 },
                 actor: c.owner
               )

      request = %{service_token: c.request.service_token, label: endpoint.label, app_port: 0}
      assert {:ok, opened} = Ingress.open_web(request, actor: SystemActor.compute())
      assert opened.binding.port == port
      assert opened.user_id == nil

      assert {:error, _} =
               Ingress.open_web(%{request | app_port: port}, actor: SystemActor.compute())

      renewal = %{service_token: c.request.service_token, stream_token: opened.ticket}
      assert {:ok, _} = Ingress.renew_web(renewal, actor: SystemActor.compute())

      assert {:ok, _} =
               Ingress.configure_endpoint(
                 %{
                   vm_id: c.vm.id,
                   expected_revision: public.policy_revision,
                   primary_port: port,
                   visibility: :private
                 },
                 actor: c.owner
               )

      assert {:error, _} = Ingress.renew_web(renewal, actor: SystemActor.compute())
      assert {:error, _} = Ingress.open_web(request, actor: SystemActor.compute())
      assert {:ok, %{closed: true}} = Ingress.close_web(renewal, actor: SystemActor.compute())
    end
  end

  test "closed and expired web streams never regain authority", c do
    [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)

    assert {:ok, _} =
             Ingress.configure_endpoint(
               %{
                 vm_id: c.vm.id,
                 expected_revision: endpoint.policy_revision,
                 primary_port: 8080,
                 visibility: :public
               },
               actor: c.owner
             )

    check all(mode <- member_of([:close, :expire]), age <- integer(1..1000), max_runs: 10) do
      assert {:ok, opened} =
               Ingress.open_web(
                 %{service_token: c.request.service_token, label: endpoint.label, app_port: 0},
                 actor: SystemActor.compute()
               )

      request = %{service_token: c.request.service_token, stream_token: opened.ticket}

      if mode == :close do
        assert {:ok, %{closed: true}} = Ingress.close_web(request, actor: SystemActor.compute())
      else
        [stream] = Ledger.read!(Marshall.Ingress.WebStream, id: opened.binding.session_id)
        Ledger.update!(stream, :renew, %{expires_at: DateTime.add(Ledger.now(), -age)})
      end

      assert {:error, _} = Ingress.renew_web(request, actor: SystemActor.compute())
    end
  end

  test "web cleanup retains referenced credentials and audits, then removes old unreferenced records",
       c do
    [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)
    old = DateTime.add(Ledger.now(), -8 * 86_400)
    {_, cookie_hash} = Token.issue(:web_cookie)

    credential =
      Ledger.create!(Marshall.Ingress.WebCredential, :record, %{
        token_hash: cookie_hash,
        user_id: c.owner.id,
        login_jti: "retention-fixture",
        vm_id: c.vm.id,
        service_id: c.service.id,
        service_generation: c.service.generation,
        label: endpoint.label,
        app_port: 0,
        expires_at: old
      })

    {_, stream_hash} = Token.issue(:web_stream)

    stream =
      Ledger.create!(Marshall.Ingress.WebStream, :record, %{
        token_hash: stream_hash,
        service_id: c.service.id,
        service_generation: c.service.generation,
        vm_id: c.vm.id,
        host_id: c.vm.host_id,
        placement_id: c.vm.current_placement_id,
        execution_epoch: c.vm.execution_epoch,
        generation: c.vm.generation,
        label: endpoint.label,
        app_port: 0,
        port: 80,
        policy_revision: endpoint.policy_revision,
        credential_id: credential.id,
        expires_at: DateTime.add(Ledger.now(), 60)
      })

    AshOban.schedule(Marshall.Ingress.WebStream, :prune)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)
    assert [_] = Ledger.read!(Marshall.Ingress.WebCredential, id: credential.id)
    Ledger.update!(stream, :renew, %{expires_at: old})
    AshOban.schedule(Marshall.Ingress.WebStream, :prune)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)
    assert [] = Ledger.read!(Marshall.Ingress.WebStream, id: stream.id)
    assert [] = Ledger.read!(Marshall.Ingress.WebCredential, id: credential.id)
    assert [_] = Ledger.read!(Marshall.Ingress.WebStream.Version, version_source_id: stream.id)

    assert [_] =
             Ledger.read!(Marshall.Ingress.WebCredential.Version,
               version_source_id: credential.id
             )
  end

  test "browser codes require matching state and are consumed exactly once", c do
    old = Application.get_env(:marshall, :ingress_zone)
    Application.put_env(:marshall, :ingress_zone, "apps.example")

    on_exit(fn ->
      if old,
        do: Application.put_env(:marshall, :ingress_zone, old),
        else: Application.delete_env(:marshall, :ingress_zone)
    end)

    [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)

    check all(bytes <- binary(length: 32), port <- member_of([0, 3000, 9999]), max_runs: 5) do
      state = Base.url_encode64(bytes, padding: false)
      digest = Base.encode16(:crypto.hash(:sha256, state), case: :lower)

      assert {:ok, started} =
               Ingress.begin_web_login(
                 %{
                   service_token: c.request.service_token,
                   label: endpoint.label,
                   app_port: port,
                   state_digest: digest
                 },
                 actor: SystemActor.compute()
               )

      assert {:ok, approved} =
               Ingress.authorize_web_login(%{ticket: started.ticket, login_token: c.token},
                 actor: c.owner
               )

      exchange = %{
        service_token: c.request.service_token,
        ticket: started.ticket,
        code: approved.code,
        state: state
      }

      wrong = Base.url_encode64(:crypto.hash(:sha256, bytes), padding: false)

      if wrong != state do
        assert {:error, _} =
                 Ingress.exchange_web_login(%{exchange | state: wrong},
                   actor: SystemActor.compute()
                 )
      end

      assert {:ok, result} = Ingress.exchange_web_login(exchange, actor: SystemActor.compute())
      assert result.hostname == started.hostname
      assert {:ok, hash} = Token.digest(result.cookie, :web_cookie)

      assert [%{app_port: ^port, user_id: user_id}] =
               Ledger.read!(Marshall.Ingress.WebCredential, token_hash: hash)

      assert user_id == c.owner.id

      assert {:ok, stream} =
               Ingress.open_web(
                 %{
                   service_token: c.request.service_token,
                   label: endpoint.label,
                   app_port: port,
                   cookie: result.cookie
                 },
                 actor: SystemActor.compute()
               )

      assert stream.user_id == c.owner.id
      renewal = %{service_token: c.request.service_token, stream_token: stream.ticket}
      assert {:ok, _} = Ingress.renew_web(renewal, actor: SystemActor.compute())
      [credential] = Ledger.read!(Marshall.Ingress.WebCredential, token_hash: hash)
      Ledger.update!(credential, :revoke, %{revoked_at: Ledger.now()})
      assert {:error, _} = Ingress.renew_web(renewal, actor: SystemActor.compute())

      assert {:error, _} = Ingress.exchange_web_login(exchange, actor: SystemActor.compute())

      assert {:error, _} =
               Ingress.authorize_web_login(%{ticket: started.ticket, login_token: c.token},
                 actor: c.owner
               )
    end
  end

  property "browser bearer purposes cannot be substituted for each other" do
    check all(
            purpose <-
              member_of([:service, :session, :web_login, :web_code, :web_cookie, :web_stream])
          ) do
      {token, hash} = Token.issue(purpose)
      assert {:ok, ^hash} = Token.digest(token, purpose)

      for other <-
            [:service, :session, :web_login, :web_code, :web_cookie, :web_stream] -- [purpose] do
        assert :error = Token.digest(token, other)
      end
    end
  end

  test "gateway HTTPS client reports the fleet wildcard without per-VM certificate work", c do
    tls = Path.expand("../../fixtures/tls", __DIR__)

    server =
      start_supervised!(
        {Bandit,
         plug: MarshallWeb.ControlAPI,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(tls, "localhost.pem"),
         keyfile: Path.join(tls, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, client} =
      Audi.Control.Client.new("https://127.0.0.1:#{port}", c.request.service_token, :gateway,
        host_id: c.vm.host_id,
        cacertfile: Path.join(tls, "ca.pem")
      )

    client = Marshall.AudiControl.connect(client)

    binding =
      Map.drop(c.request, [:service_token, :certificate_fingerprint, :certificate_expires_at])

    assert {:ok, catalog} = Audi.Control.Client.gateway_catalog(client)
    assert catalog.host_id == c.vm.host_id and catalog.service_generation == c.service.generation
    assert [%{vm_id: vm_id, placement_id: placement_id}] = catalog.entries
    assert vm_id == c.vm.id and placement_id == c.vm.current_placement_id
    assert [] = Ledger.read!(Marshall.Ingress.Route, vm_id: c.vm.id)

    Marshall.FleetCertificateFixtures.install!(
      c.service,
      c.request.certificate_expires_at,
      c.request.certificate_fingerprint
    )

    report =
      Map.merge(binding, %{
        certificate_fingerprint: c.request.certificate_fingerprint,
        certificate_expires_at: DateTime.to_iso8601(c.request.certificate_expires_at)
      })

    assert {:ok, reported} = Audi.Control.Client.report_ready_route(client, report)
    [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)
    assert reported.label == endpoint.label

    assert {:ok, route} =
             Ingress.current_route(%{label: endpoint.label}, actor: SystemActor.compute())

    assert route.certificate_fingerprint == report.certificate_fingerprint

    assert {:error, _} =
             Audi.Control.Client.report_ready_route(client, %{
               report
               | generation: report.generation + 1
             })

    assert {:ok, _} = Ingress.disable_service(%{id: c.service.id}, actor: SystemActor.compute())
    assert {:error, :unauthorized} = Audi.Control.Client.report_ready_route(client, report)
  end

  test "catalog discovery excludes other hosts and stopped VMs and requires fresh gateway authority",
       c do
    # Usage-based admission can reuse the first host. Exclude it only during
    # setup so the second real provision action selects the other fixture host.
    [first_host] = Ledger.read!(Host, id: c.vm.host_id)
    Ledger.update!(first_host, :configure, %{enabled: false})
    other = Marshall.TerminalFixtures.terminal_fixture()
    Ledger.update!(first_host, :configure, %{enabled: true})
    assert other.vm.host_id != c.vm.host_id

    assert {:ok, %{entries: [%{vm_id: vm}]}} =
             Ingress.gateway_catalog(%{token: c.request.service_token},
               actor: SystemActor.compute()
             )

    assert vm == c.vm.id
    [host] = Ledger.read!(Host, id: c.vm.host_id)
    Ledger.update!(host, :report, %{reported_at: DateTime.add(Ledger.now(), -60)})

    assert {:error, _} =
             Ingress.gateway_catalog(%{token: c.request.service_token},
               actor: SystemActor.compute()
             )

    Ledger.update!(host, :report, %{reported_at: Ledger.now()})
    [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: c.vm.id)

    Ledger.intent!(vm, %{
      desired_state: :stopped,
      generation: vm.generation + 1
    })

    assert {:ok, %{entries: []}} =
             Ingress.gateway_catalog(%{token: c.request.service_token},
               actor: SystemActor.compute()
             )

    assert {:error, _} =
             Ingress.gateway_catalog(%{token: c.request.service_token}, actor: c.owner)

    {dns_token, _} = Token.issue()

    assert {:ok, _} =
             Ingress.configure_service(%{name: "catalog-dns", role: :dns, token: dns_token},
               actor: SystemActor.compute()
             )

    assert {:error, _} =
             Ingress.gateway_catalog(%{token: dns_token}, actor: SystemActor.compute())
  end
end
