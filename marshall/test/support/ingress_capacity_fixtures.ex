defmodule Marshall.IngressCapacityFixtures do
  @moduledoc false
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress
  alias Marshall.Ingress.Token
  alias Marshall.Repo

  @spec fixture() :: map()
  def fixture do
    f = Marshall.TerminalFixtures.terminal_fixture()
    {token, _} = Token.issue()

    {:ok, dns} =
      Ingress.configure_service(%{name: "dns", role: :dns, token: token}, actor: actor())

    {gateway_token, _} = Token.issue()

    params = %{
      name: "gateway",
      role: :gateway,
      host_id: f.vm.host_id,
      addresses: ["192.0.2.9"],
      token: gateway_token
    }

    {:ok, gateway} = Ingress.configure_service(params, actor: actor())
    {public, _} = :crypto.generate_key(:eddsa, :ed25519)
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, public::binary>>)
    {:ok, _} = Ingress.publish_host_key(%{token: gateway_token, public_key: key}, actor: actor())

    binding = %{
      service_token: gateway_token,
      service_generation: gateway.generation,
      vm_id: f.vm.id,
      placement_id: f.vm.current_placement_id,
      execution_epoch: f.vm.execution_epoch,
      generation: f.vm.generation
    }

    expiry = DateTime.add(Ledger.now(), 3600)
    fingerprint = String.duplicate("a", 64)
    Marshall.FleetCertificateFixtures.install!(gateway, expiry, fingerprint)

    request =
      Map.merge(binding, %{
        certificate_fingerprint: fingerprint,
        certificate_expires_at: expiry
      })

    {:ok, route} = Ingress.report_ready_route(request, actor: actor())

    Map.merge(f, %{
      token: token,
      dns: dns,
      params: params,
      gateway: gateway,
      route: route,
      request: request
    })
  end

  # @cc [owner:ghuntley,label:verification] audi-publication-capacity-fixture
  # This fixture MUST run in a rollback-owned sandbox or an exclusively created
  # capacity database that its caller cleans up. It MUST model 10,000 routes and 100
  # distinct gateways. It MUST NOT relax production deadlines or claim guest,
  # issuance, readiness-refresh or full-fleet throughput from publication timing.
  @spec populate(map()) :: Postgrex.Result.t()
  def populate(c) do
    sql = fn query, params -> Ecto.Adapters.SQL.query!(Repo, query, params, log: false) end
    sql.("SET CONSTRAINTS ALL DEFERRED", [])

    sql.(
      "CREATE TEMP TABLE audi_capacity_hosts ON COMMIT DROP AS SELECT n, gen_random_uuid() AS host, gen_random_uuid() AS service, gen_random_uuid() AS pool FROM generate_series(1,100) n",
      []
    )

    sql.(
      "CREATE TEMP TABLE audi_capacity_vms ON COMMIT DROP AS SELECT h.host, h.service, h.pool, gen_random_uuid() AS vm, gen_random_uuid() AS placement FROM audi_capacity_hosts h CROSS JOIN generate_series(1,100)",
      []
    )

    host = Ecto.UUID.dump!(c.vm.host_id)
    vm = Ecto.UUID.dump!(c.vm.id)
    service = Ecto.UUID.dump!(c.gateway.id)

    sql.(
      """
      INSERT INTO compute_hosts
      SELECT (jsonb_populate_record(NULL::compute_hosts, to_jsonb(h) || jsonb_build_object(
        'id', p.host, 'name', 'capacity-' || p.host::text,
        'machine_id', 'sha256:' || md5(p.host::text) || md5(p.service::text)))).*
      FROM compute_hosts h CROSS JOIN audi_capacity_hosts p WHERE h.id = $1
      """,
      [host]
    )

    sql.(
      """
      INSERT INTO compute_storage_pools
      SELECT (jsonb_populate_record(NULL::compute_storage_pools,
        to_jsonb(s) || jsonb_build_object('id', p.pool, 'host_id', p.host))).*
      FROM compute_storage_pools s CROSS JOIN audi_capacity_hosts p
      WHERE s.id = (SELECT pool_id FROM compute_workload_placements
        WHERE id = (SELECT current_placement_id FROM compute_virtual_machines WHERE id = $1))
      """,
      [vm]
    )

    sql.(
      """
      INSERT INTO ingress_services
      SELECT (jsonb_populate_record(NULL::ingress_services, to_jsonb(s) || jsonb_build_object(
        'id', p.service, 'host_id', p.host, 'name', 'capacity-' || p.service::text,
        'token_hash', ('\\x' || md5(p.service::text) || md5(p.host::text)),
        'addresses', jsonb_build_array('192.0.2.' || p.n::text)))).*
      FROM ingress_services s CROSS JOIN audi_capacity_hosts p WHERE s.id = $1
      """,
      [service]
    )

    sql.(
      """
      INSERT INTO ingress_fleet_certificate_installations
      SELECT (jsonb_populate_record(NULL::ingress_fleet_certificate_installations,
        to_jsonb(i) || jsonb_build_object(
          'id', gen_random_uuid(), 'host_id', p.host, 'service_id', p.service))).*
      FROM ingress_fleet_certificate_installations i CROSS JOIN audi_capacity_hosts p
      WHERE i.host_id = $1
      """,
      [host]
    )

    sql.(
      """
      INSERT INTO compute_virtual_machines
      SELECT (jsonb_populate_record(NULL::compute_virtual_machines, to_jsonb(v) || jsonb_build_object(
        'id', p.vm, 'host_id', p.host, 'current_placement_id', p.placement,
        'idempotency_key', p.vm::text, 'name', 'bulk-' || replace(p.vm::text, '-', '')))).*
      FROM compute_virtual_machines v CROSS JOIN audi_capacity_vms p WHERE v.id = $1
      """,
      [vm]
    )

    sql.(
      """
      INSERT INTO compute_workload_placements
      SELECT (jsonb_populate_record(NULL::compute_workload_placements, to_jsonb(w) || jsonb_build_object(
        'id', p.placement, 'vm_id', p.vm, 'host_id', p.host, 'pool_id', p.pool))).*
      FROM compute_workload_placements w CROSS JOIN audi_capacity_vms p
      WHERE w.id = (SELECT current_placement_id FROM compute_virtual_machines WHERE id = $1)
      """,
      [vm]
    )

    sql.(
      """
      INSERT INTO compute_operations
      SELECT (jsonb_populate_record(NULL::compute_operations, to_jsonb(o) || jsonb_build_object(
        'id', gen_random_uuid(), 'vm_id', p.vm, 'host_id', p.host, 'placement_id', p.placement))).*
      FROM compute_operations o CROSS JOIN audi_capacity_vms p
      WHERE o.vm_id = $1 AND o.status = 'completed' AND o.kind IN ('start', 'provision')
      """,
      [vm]
    )

    sql.(
      """
      INSERT INTO ingress_endpoints
      SELECT (jsonb_populate_record(NULL::ingress_endpoints, to_jsonb(e) || jsonb_build_object(
        'id', gen_random_uuid(), 'vm_id', p.vm, 'label', 'bulk-' || replace(p.vm::text, '-', '')))).*
      FROM ingress_endpoints e CROSS JOIN audi_capacity_vms p WHERE e.vm_id = $1
      """,
      [vm]
    )

    sql.(
      """
      INSERT INTO ingress_routes
      SELECT (jsonb_populate_record(NULL::ingress_routes, to_jsonb(r) || jsonb_build_object(
        'id', gen_random_uuid(), 'vm_id', p.vm, 'host_id', p.host, 'placement_id', p.placement,
        'service_id', p.service, 'label', 'bulk-' || replace(p.vm::text, '-', '')))).*
      FROM ingress_routes r CROSS JOIN audi_capacity_vms p WHERE r.vm_id = $1
      """,
      [vm]
    )

    sql.(
      "UPDATE compute_virtual_machines SET archived_at = clock_timestamp() AT TIME ZONE 'UTC' WHERE id = $1",
      [vm]
    )
  end

  defp actor, do: SystemActor.compute()
end
