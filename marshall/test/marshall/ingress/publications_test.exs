defmodule Marshall.Ingress.PublicationsTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger, Operation, VirtualMachine}
  alias Marshall.Ingress
  alias Marshall.Ingress.{FleetCertificate, Publication, Route, Token}
  @zone "apps.example.test"
  @tls Path.expand("../../fixtures/tls", __DIR__)

  setup do
    old = Application.get_env(:marshall, :ingress_zone)
    Application.put_env(:marshall, :ingress_zone, @zone)

    on_exit(fn ->
      if old,
        do: Application.put_env(:marshall, :ingress_zone, old),
        else: Application.delete_env(:marshall, :ingress_zone)
    end)

    Marshall.IngressCapacityFixtures.fixture()
  end

  test "complete publication matches current route and advances only its own metadata",
       c do
    [route] = Ledger.read!(Route, id: c.route.id)
    assert {:ok, first} = snapshot(c)
    assert first.revision == 1 and first.zone == @zone and first.ttl == 5000
    assert [%{label: label, addresses: ["192.0.2.9"], ttl: ttl}] = first.routes
    assert label == c.route.label and ttl in 1..5000
    assert first.proofs == []
    assert {:ok, point} = Ingress.current_route(%{label: label}, actor: actor())
    assert point.addresses == hd(first.routes).addresses
    assert {:ok, second} = snapshot(c)
    assert second.revision == 2
    assert [%{revision: 2}] = Ledger.read!(Publication, zone: @zone)
    assert [^route] = Ledger.read!(Route, id: route.id)
    refute inspect(second) =~ "https://ca.example"
    refute inspect(second) =~ c.token
  end

  test "user actors, gateway credentials, wrong zones and revoked DNS identities cannot publish",
       c do
    assert {:error, _} = Ingress.dns_snapshot(%{token: c.token, zone: @zone}, actor: c.owner)

    assert {:error, _} =
             Ingress.dns_snapshot(%{token: c.params.token, zone: @zone}, actor: actor())

    assert {:error, _} =
             Ingress.dns_snapshot(%{token: c.token, zone: "wrong.example"}, actor: actor())

    assert {:ok, _} = Ingress.disable_service(%{id: c.dns.id}, actor: actor())
    assert {:error, _} = snapshot(c)
    assert [] = Ledger.read!(Publication)
  end

  test "expired route is omitted until readiness is reported again", c do
    [route] = Ledger.read!(Route, id: c.route.id)
    Ledger.update!(route, :refresh, %{expires_at: DateTime.add(Ledger.now(), -1), revision: 2})
    assert {:ok, %{routes: [], proofs: []}} = snapshot(c)
    assert {:ok, _} = Ingress.report_ready_route(c.request, actor: actor())
    assert {:ok, %{routes: [_], proofs: []}} = snapshot(c)
  end

  test "gateway rotation removes route publication", c do
    assert {:ok, %{routes: [_], proofs: []}} = snapshot(c)

    assert {:ok, _} =
             Ingress.configure_service(%{c.params | addresses: ["192.0.2.10"]}, actor: actor())

    assert {:ok, %{routes: [], proofs: []}} = snapshot(c)
  end

  test "wildcard rotation removes the old route before its report lease expires", c do
    assert {:ok, %{routes: [_], proofs: []}} = snapshot(c)
    [route] = Ledger.read!(Route, id: c.route.id)
    assert DateTime.compare(route.expires_at, Ledger.now()) == :gt

    [active] = Ledger.read!(FleetCertificate, zone: @zone, status: :active)
    Ledger.update!(active, :retire, %{})

    Ledger.create!(FleetCertificate, :enqueue, %{generation: 2, zone: @zone})
    |> Ledger.update!(:bind_order, %{
      order_url: "https://ca.example.test/order/2",
      finalize_url: "https://ca.example.test/finalize/2",
      authorization_url: "https://ca.example.test/auth/2"
    })
    |> Ledger.update!(:finish_issued, %{
      chain_pem: "fixture-replacement-chain",
      fingerprint: String.duplicate("b", 64),
      expires_at: DateTime.add(Ledger.now(), 3600)
    })
    |> Ledger.update!(:activate, %{})

    assert {:ok, %{routes: [], proofs: []}} = snapshot(c)
    assert {:error, _} = Ingress.current_route(%{label: c.route.label}, actor: actor())
  end

  test "host freshness, connection, enabled state and completed start are required", c do
    [host] = Ledger.read!(Host, id: c.vm.host_id)

    for timestamp <- [nil, DateTime.add(Ledger.now(), -60), DateTime.add(Ledger.now(), 60)] do
      Ledger.update!(host, :report, %{reported_at: timestamp})
      assert {:ok, %{routes: [], proofs: []}} = snapshot(c)
    end

    Ledger.update!(host, :report, %{reported_at: Ledger.now()})
    Ledger.update!(host, :disconnect, %{connection_session_id: nil})
    assert {:ok, %{routes: [], proofs: []}} = snapshot(c)
    Ledger.update!(host, :connect, %{connection_session_id: host.connection_session_id})
    Ledger.update!(host, :configure, %{enabled: false})
    assert {:ok, %{routes: [], proofs: []}} = snapshot(c)
    Ledger.update!(host, :configure, %{enabled: true})
    [operation] = Ledger.read!(Operation, vm_id: c.vm.id)
    # Construct a pending-operation fixture: completed operations cannot be cancelled.
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE compute_operations SET status = 'pending' WHERE id = $1",
      [Ecto.UUID.dump!(operation.id)]
    )

    assert {:ok, %{routes: [], proofs: []}} = snapshot(c)
    [operation] = Ledger.read!(Operation, id: operation.id)
    Ledger.update!(operation, :complete, %{})
    assert {:ok, %{routes: [_], proofs: []}} = snapshot(c)
  end

  test "stale execution generations never publish retained route rows", c do
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

    check all(increment <- integer(1..10_000), test_cases: 20) do
      Ledger.intent!(vm, %{generation: vm.generation + increment})
      assert {:ok, %{routes: [], proofs: []}} = snapshot(c)
      assert {:error, _} = Ingress.current_route(%{label: c.route.label}, actor: actor())
    end
  end

  test "real HTTPS API and Audi receiver populate a local DNS directory", c do
    server =
      start_supervised!(
        {Bandit,
         plug: MarshallWeb.ControlAPI,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@tls, "localhost.pem"),
         keyfile: Path.join(@tls, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, client} =
      Audi.Control.Client.new("https://127.0.0.1:#{port}", c.token, :dns,
        cacertfile: Path.join(@tls, "ca.pem")
      )

    client = Marshall.AudiControl.connect(client)

    # Audi's directory publishes through its read view (ADR-0140 phase 6).
    directory = :"marshall_publications_directory_#{System.unique_integer([:positive])}"

    for child <- Audi.DNS.Directory.children(name: directory) do
      spec = Supervisor.child_spec(child, [])
      start_supervised!(Supervisor.child_spec(spec, id: {spec.id, directory}))
    end

    assert {:ok, first} = Audi.Control.Client.dns_snapshot(client, @zone)

    assert :ok =
             Audi.DNS.Directory.publish(
               directory,
               first.revision,
               first.entries,
               first.expires_at
             )

    assert {:ok, 1, %{addresses: [{192, 0, 2, 9}]}} =
             Audi.DNS.Directory.lookup(directory, c.route.label <> "." <> @zone)

    assert {:ok, 1, nil} =
             Audi.DNS.Directory.lookup(
               directory,
               "_acme-challenge." <> c.route.label <> "." <> @zone
             )

    {:ok, _} = Ingress.disable_service(%{id: c.gateway.id}, actor: actor())
    assert {:ok, second} = Audi.Control.Client.dns_snapshot(client, @zone)
    assert second.revision == 2 and second.entries == %{}

    assert :ok =
             Audi.DNS.Directory.publish(
               directory,
               second.revision,
               second.entries,
               second.expires_at
             )

    assert {:error, :stale} =
             Audi.DNS.Directory.publish(
               directory,
               first.revision,
               first.entries,
               first.expires_at
             )
  end

  defp snapshot(c), do: Ingress.dns_snapshot(%{token: c.token, zone: @zone}, actor: actor())

  for zone <- ["Pacific/Honolulu", "Pacific/Kiritimati"] do
    @session_zone zone
    test "publication freshness and expiry are independent of #{@session_zone}", c do
      Ecto.Adapters.SQL.query!(Repo, "SELECT set_config('TimeZone', $1, true)", [@session_zone],
        log: false
      )

      assert {:ok, %{routes: [%{ttl: route_ttl}], proofs: []}} = snapshot(c)
      assert route_ttl in 1..5000

      [route] = Ledger.read!(Route, id: c.route.id)
      Ledger.update!(route, :refresh, %{expires_at: DateTime.add(Ledger.now(), -1), revision: 2})
      assert {:ok, %{routes: [], proofs: []}} = snapshot(c)

      assert {:ok, _} = Ingress.report_ready_route(c.request, actor: actor())
      assert {:ok, %{routes: [_], proofs: []}} = snapshot(c)
    end
  end

  @tag timeout: 60_000
  test "10,000 active endpoint rows fit but an extra row cannot silently truncate the catalog",
       c do
    # Synthetic rows verify the catalog bound, not admission capacity or guest
    # execution. They live only inside this test's rollback-owned sandbox.
    Ecto.Adapters.SQL.query!(Repo, "SET CONSTRAINTS ALL DEFERRED", [], log: false)

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TEMP TABLE audi_snapshot_population (vm uuid, placement uuid, endpoint uuid) ON COMMIT DROP",
      [],
      log: false
    )

    # Exercise stale small-table estimates before inserting the large fixture.
    # Eligibility must not rescan the complete inventory for every endpoint.
    Ecto.Adapters.SQL.query!(
      Repo,
      "ANALYZE compute_virtual_machines, compute_workload_placements, ingress_endpoints",
      [],
      log: false
    )

    populate(c.vm.id, 9999)
    [host] = Ledger.read!(Host, id: c.vm.host_id)
    Ledger.update!(host, :report, %{reported_at: Ledger.now()})
    assert {:ok, _} = Ingress.report_ready_route(c.request, actor: actor())
    handler = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:marshall, :repo, :query],
        fn _event, timings, metadata, _ ->
          if String.contains?(metadata.query, "WITH clock AS MATERIALIZED") do
            outcome =
              case metadata.result do
                {:ok, _} -> :ok
                {:error, %Postgrex.Error{postgres: postgres}} -> Map.get(postgres || %{}, :code)
                {:error, error} -> error.__struct__
              end

            send(
              owner,
              {:snapshot_query,
               System.convert_time_unit(timings.total_time, :native, :microsecond), outcome}
            )
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    result = snapshot(c)
    assert_receive {:snapshot_query, elapsed, outcome}, 1000

    assert match?({:ok, %{routes: [_], proofs: [], revision: 1}}, result),
           inspect(%{result: result, query_microseconds: elapsed, query_outcome: outcome})

    populate(c.vm.id, 1)
    assert {:error, _} = snapshot(c)
    assert [%{revision: 1}] = Ledger.read!(Publication, zone: @zone)
  end

  @tag :capacity
  @tag timeout: 120_000
  test "measure complete publications for 100 gateways and 10,000 ready routes", c do
    Marshall.IngressCapacityFixtures.populate(c)

    samples =
      for _ <- 1..10 do
        Ecto.Adapters.SQL.query!(
          Repo,
          "UPDATE compute_hosts SET reported_at = clock_timestamp() AT TIME ZONE 'UTC'",
          [],
          log: false
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "UPDATE ingress_routes SET expires_at = (clock_timestamp() AT TIME ZONE 'UTC') + interval '5 seconds'",
          [],
          log: false
        )

        {elapsed, result} = :timer.tc(fn -> snapshot(c) end)
        assert {:ok, %{routes: routes, proofs: []}} = result
        assert length(routes) == 10_000
        assert MapSet.size(MapSet.new(routes, & &1.label)) == 10_000
        assert MapSet.size(MapSet.new(routes, & &1.addresses)) == 100
        assert elapsed < 5_000_000
        elapsed
      end

    IO.puts(
      JSON.encode!(%{
        measurement: "audi_publication_capacity",
        gateways: 100,
        routes: 10_000,
        samples: length(samples),
        microseconds: samples,
        scope: "real publication action over synthetic ready database rows; no physical guests"
      })
    )
  end

  @tag :capacity
  @tag :readiness_capacity
  @tag timeout: 120_000
  test "measure authenticated readiness refresh for 100 VMs within a 10,000-VM inventory", c do
    Marshall.IngressCapacityFixtures.populate(c)

    %{rows: [[service]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT service FROM audi_capacity_hosts WHERE n = 1", [],
        log: false
      )

    {token, digest} = Token.issue()

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE ingress_services SET token_hash = $1 WHERE id = $2",
      [digest, service],
      log: false
    )

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT vm::text, placement::text FROM audi_capacity_vms WHERE service = $1 ORDER BY vm",
        [service],
        log: false
      )

    requests =
      Enum.map(rows, fn [vm, placement] ->
        Map.merge(c.request, %{service_token: token, vm_id: vm, placement_id: placement})
      end)

    assert length(requests) == 100

    samples =
      for _ <- 1..3 do
        Ecto.Adapters.SQL.query!(
          Repo,
          "UPDATE compute_hosts SET reported_at = clock_timestamp() AT TIME ZONE 'UTC'",
          [],
          log: false
        )

        {elapsed, timings} =
          :timer.tc(fn ->
            Enum.map(requests, fn request ->
              {duration, result} =
                :timer.tc(fn -> Ingress.report_ready_route(request, actor: actor()) end)

              assert {:ok, _} = result
              duration
            end)
          end)

        %{rows: [[fresh]]} =
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT count(*) FROM ingress_routes WHERE service_id = $1 AND expires_at > (clock_timestamp() AT TIME ZONE 'UTC')",
            [service],
            log: false
          )

        sample = %{
          round_microseconds: elapsed,
          fresh_routes: fresh,
          request_max_microseconds: Enum.max(timings)
        }

        IO.puts(JSON.encode!(Map.put(sample, :measurement, "audi_readiness_capacity_round")))
        assert fresh == 100
        assert elapsed < 5_000_000
        sample
      end

    IO.puts(
      JSON.encode!(%{
        measurement: "audi_readiness_capacity",
        inventory: 10_000,
        measured_gateway_vms: 100,
        rounds: samples,
        scope: "sequential authenticated Ash actions; excludes TLS, HTTP and concurrent gateways"
      })
    )
  end

  defp populate(vm_id, count) do
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE audi_snapshot_population", [], log: false)

    Ecto.Adapters.SQL.query!(
      Repo,
      "INSERT INTO audi_snapshot_population SELECT gen_random_uuid(), gen_random_uuid(), gen_random_uuid() FROM generate_series(1, $1::integer)",
      [count],
      log: false
    )

    id = Ecto.UUID.dump!(vm_id)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO compute_virtual_machines
      SELECT (jsonb_populate_record(NULL::compute_virtual_machines,
        to_jsonb(v) || jsonb_build_object('id', p.vm, 'current_placement_id', p.placement,
          'idempotency_key', p.vm::text, 'name', 'bulk-' || replace(p.vm::text, '-', '')))).*
      FROM compute_virtual_machines v CROSS JOIN audi_snapshot_population p WHERE v.id = $1
      """,
      [id],
      log: false
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO compute_workload_placements
      SELECT (jsonb_populate_record(NULL::compute_workload_placements,
        to_jsonb(w) || jsonb_build_object('id', p.placement, 'vm_id', p.vm))).*
      FROM compute_virtual_machines v
      JOIN compute_workload_placements w ON w.id = v.current_placement_id
      CROSS JOIN audi_snapshot_population p WHERE v.id = $1
      """,
      [id],
      log: false
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO ingress_endpoints
      SELECT (jsonb_populate_record(NULL::ingress_endpoints,
        to_jsonb(e) || jsonb_build_object('id', p.endpoint, 'vm_id', p.vm,
          'label', 'bulk-' || replace(p.vm::text, '-', '')))).*
      FROM ingress_endpoints e CROSS JOIN audi_snapshot_population p WHERE e.vm_id = $1
      """,
      [id],
      log: false
    )
  end

  test "relocation suppresses retained source publications and publishes the completed destination",
       c do
    alias Marshall.Compute.RelocationCapacity
    Marshall.ComputeFixtures.host_fixture()

    {:ok, relocation} =
      Ledger.transaction(fn ->
        hosts =
          Host |> Ledger.read!() |> Enum.sort_by(& &1.id) |> Enum.map(&Ledger.lock!(Host, &1.id))

        vm = Ledger.lock!(VirtualMachine, c.vm.id)
        RelocationCapacity.reserve_locked!(vm, hosts, c.owner, Ash.UUID.generate())
      end)

    assert {:ok, %{routes: [_], proofs: []}} = snapshot(c)

    # Synthetic retained coordination evidence exercises discovery rejection;
    # this is not a physical transfer or readiness acceptance test.
    import_id = Ash.UUID.generate()

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO compute_source_permit_requests
        (id, relocation_id, source_host_id, revision, request, status)
      VALUES ($1, $2, $3, 1, '{}'::jsonb, 'pending')
      """,
      Enum.map([import_id, relocation.id, relocation.source_host_id], &Ecto.UUID.dump!/1),
      log: false
    )

    activation =
      Ledger.create!(Operation, :enqueue, %{
        vm_id: c.vm.id,
        placement_id: relocation.destination_placement_id,
        execution_epoch: relocation.destination_epoch,
        generation: c.vm.generation + 1,
        kind: :start,
        initiator: :relocation,
        relocation_id: relocation.id
      })

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE compute_relocations SET phase = 'handoff' WHERE id = $1",
      [Ecto.UUID.dump!(relocation.id)]
    )

    [relocation] = Ledger.read!(Marshall.Compute.Relocation, id: relocation.id)

    Ledger.update!(relocation, :record_commit, %{
      committed_at: Ledger.now(),
      import_request_id: import_id,
      activation_operation_id: activation.id,
      activation_generation: activation.generation
    })

    assert {:ok, %{routes: [], proofs: []}} = snapshot(c)
    assert {:error, _} = Ingress.current_route(%{label: c.route.label}, actor: actor())

    # Model the completed coordinator state inside the rollback-owned sandbox.
    # These rows exercise read/report predicates, not physical import or cleanup.
    [committed] = Ledger.read!(Marshall.Compute.Relocation, id: relocation.id)

    committed
    |> Ledger.update!(:confirm_readiness, %{})
    |> Ledger.update!(:complete, %{finished_at: Ledger.now()})

    Ledger.update!(activation, :complete, %{})
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    vm = Ledger.intent!(vm, %{desired_state: :stopped})

    Ledger.update!(vm, :handoff, %{
      current_placement_id: relocation.destination_placement_id,
      execution_epoch: relocation.destination_epoch,
      generation: activation.generation,
      desired_state: :running,
      observed_state: :running,
      outcome_sequence: 1,
      observed_at: Ledger.now()
    })

    [destination] = Ledger.read!(Host, id: relocation.destination_host_id)
    Ledger.update!(destination, :connect, %{connection_session_id: Ash.UUID.generate()})
    Ledger.update!(destination, :report, %{reported_at: Ledger.now()})
    {destination_token, _} = Token.issue()

    assert {:ok, gateway} =
             Ingress.configure_service(
               %{
                 c.params
                 | name: "destination",
                   host_id: destination.id,
                   token: destination_token,
                   addresses: ["192.0.2.10"]
               },
               actor: actor()
             )

    {public, _} = :crypto.generate_key(:eddsa, :ed25519)
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, public::binary>>)

    assert {:ok, _} =
             Ingress.publish_host_key(%{token: destination_token, public_key: key},
               actor: actor()
             )

    # Fresh retained source evidence cannot be republished after the handoff.
    assert {:ok, %{routes: [], proofs: []}} = snapshot(c)
    assert {:error, _} = Ingress.report_ready_route(c.request, actor: actor())

    request = %{
      c.request
      | service_token: destination_token,
        service_generation: gateway.generation,
        placement_id: relocation.destination_placement_id,
        execution_epoch: relocation.destination_epoch,
        generation: activation.generation
    }

    Ledger.create!(Marshall.Ingress.FleetCertificateInstallation, :record, %{
      host_id: gateway.host_id,
      service_id: gateway.id,
      service_generation: gateway.generation,
      zone: Application.fetch_env!(:marshall, :ingress_zone),
      generation: 1,
      fingerprint: c.request.certificate_fingerprint
    })

    assert {:ok, ready} = Ingress.report_ready_route(request, actor: actor())
    assert ready.label == c.route.label
    assert {:ok, %{routes: [published], proofs: []}} = snapshot(c)
    assert published.label == c.route.label
    assert published.addresses == ["192.0.2.10"]
    assert {:ok, point} = Ingress.current_route(%{label: c.route.label}, actor: actor())
    assert point.addresses == published.addresses
  end

  test "revision exhaustion fails closed and does not reset persisted ordering", c do
    assert {:ok, _} = snapshot(c)
    [publication] = Ledger.read!(Publication, zone: @zone)
    Ledger.update!(publication, :advance, %{revision: 9_223_372_036_854_775_807})
    assert {:error, _} = snapshot(c)
    assert [%{revision: 9_223_372_036_854_775_807}] = Ledger.read!(Publication, zone: @zone)
  end

  defp actor, do: SystemActor.compute()
end
