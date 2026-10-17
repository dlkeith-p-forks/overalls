defmodule Marshall.SharingMatrixFixture do
  @moduledoc "Shared VM fixture composing terminal, SSH and private web entries for one member."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, Operation, ProvisionerControl, VirtualMachine}
  alias Marshall.Ingress
  alias Marshall.Ingress.{Endpoint, Token}

  @type t :: %{
          host: Marshall.Compute.Host.t(),
          vm: VirtualMachine.t(),
          owner: Marshall.Accounts.User.t(),
          member: Marshall.Accounts.User.t(),
          member_key: Marshall.SSH.Key.t(),
          member_public_key: String.t(),
          member_token: String.t(),
          service: Marshall.Ingress.Service.t(),
          service_token: String.t(),
          label: String.t(),
          credential: Marshall.Compute.Credentials.Issued.t(),
          connection: %{session_id: String.t(), epoch: pos_integer()},
          report: OverallsProtocol.report()
        }

  @spec create(keyword()) :: t()
  def create(opts \\ []) do
    # Earlier runs of the same property share this sandbox transaction; pin
    # placement by admitting only the fixture host created below. Committed
    # callers pass disable_others: false and assert placement instead, so the
    # pre-test committed inventory is preserved.
    if Keyword.get(opts, :disable_others, true) do
      for host <- Ledger.read!(Marshall.Compute.Host),
          do: Ledger.update!(host, :configure, %{enabled: false})
    end

    source = Marshall.TerminalFixtures.terminal_fixture(%{profile: :oss, vcpu: 1})
    member = Marshall.ComputeFixtures.user()
    public_key = key_text()
    {:ok, key} = Marshall.SSH.add_key(%{public_key: public_key}, actor: member)
    {service_token, _} = Token.issue()

    {:ok, service} =
      Ingress.configure_service(
        %{
          name: "matrix-" <> Ash.UUID.generate(),
          role: :gateway,
          host_id: source.vm.host_id,
          token: service_token,
          addresses: ["192.0.2.9"]
        },
        actor: SystemActor.compute()
      )

    {public, _} = :crypto.generate_key(:eddsa, :ed25519)
    host_key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, public::binary>>)

    {:ok, _} =
      Ingress.publish_host_key(%{token: service_token, public_key: host_key},
        actor: SystemActor.compute()
      )

    %{
      host: source.host,
      vm: source.vm,
      owner: source.owner,
      member: member,
      member_key: key,
      member_public_key: public_key,
      member_token: Marshall.TerminalFixtures.user_token(member),
      service: service,
      service_token: service_token,
      label: private_endpoint(source.vm, source.owner).label,
      credential: source.credential,
      connection: source.connection,
      report: source.report
    }
  end

  @spec private_endpoint(VirtualMachine.t(), Marshall.Accounts.User.t()) :: Endpoint.t()
  def private_endpoint(vm, owner) do
    [endpoint] = Ledger.read!(Endpoint, vm_id: vm.id)

    {:ok, configured} =
      Ingress.configure_endpoint(
        %{
          vm_id: vm.id,
          expected_revision: endpoint.policy_revision,
          primary_port: 8080,
          visibility: :private
        },
        actor: owner
      )

    configured
  end

  # @cc [owner:ghuntley,label:verification] sharing-matrix-second-workload
  # A second workload on the fixture host MUST complete its own real provision
  # and running evidence exchange before any entry probe; the returned endpoint
  # is configured private by the owner.
  @spec provision_second(t()) :: %{vm: VirtualMachine.t(), label: String.t()}
  def provision_second(fixture) do
    {:ok, vm} =
      Marshall.Compute.provision(
        Marshall.ComputeFixtures.request(%{profile: :oss, vcpu: 1}),
        actor: fixture.owner
      )

    [operation] = Ledger.read!(Operation, vm_id: vm.id)

    {:ok, _} =
      ProvisionerControl.exchange_execution(
        fixture.credential.token,
        Map.merge(fixture.connection, %{
          report: %{fixture.report | sequence: 2, sampled_at: Ledger.now()},
          acknowledgements: [],
          outcomes: [
            %{
              id: Ash.UUID.generate(),
              vm_id: vm.id,
              placement_id: vm.current_placement_id,
              execution_epoch: vm.execution_epoch,
              operation_id: operation.id,
              generation: vm.generation,
              sequence: 1,
              state: :running,
              compute_empty: false,
              disk_present: true,
              cleanup_complete: false,
              reason: :none
            }
          ]
        })
      )

    [vm] = Ledger.read!(VirtualMachine, id: vm.id)
    %{vm: vm, label: private_endpoint(vm, fixture.owner).label}
  end

  @spec key_text() :: String.t()
  def key_text,
    do:
      "ssh-ed25519 " <>
        Base.encode64(<<11::32, "ssh-ed25519", 32::32, :crypto.strong_rand_bytes(32)::binary>>)

  @spec fresh(t()) :: :ok
  def fresh(fixture) do
    [host] = Ledger.read!(Marshall.Compute.Host, id: fixture.host.id)
    Ledger.update!(host, :report, %{reported_at: Ledger.now()})
    :ok
  end

  # @cc [owner:ghuntley,label:verification] sharing-matrix-refusal-inventory
  # The durable inventory MUST enumerate every VM/member-scoped durable table the
  # composed entries can mutate, including versions. Terminal ticket rows and
  # terminal events are the documented mutable receipts and stay outside this
  # refusal oracle, matching the recorded terminal attachment scope.
  @spec inventory(t(), [VirtualMachine.t()] | nil) :: [{String.t(), String.t()}]
  def inventory(fixture, vms \\ nil) do
    vms = vms || [fixture.vm]
    vm_ids = Enum.map(vms, &Ecto.UUID.dump!(&1.id))
    member = Ecto.UUID.dump!(fixture.member.id)

    sections = [
      {"compute_virtual_machines", "id = ANY($1::uuid[])"},
      {"compute_operations", "vm_id = ANY($1::uuid[])"},
      {"compute_reservations", "vm_id = ANY($1::uuid[])"},
      {"compute_workload_placements", "vm_id = ANY($1::uuid[])"},
      {"access_grants", "vm_id = ANY($1::uuid[])"},
      {"access_changes", "vm_id = ANY($1::uuid[])"},
      {"access_grants_versions",
       "version_source_id IN (SELECT id FROM access_grants WHERE vm_id = ANY($1::uuid[]))"},
      {"terminal_sessions", "vm_id = ANY($1::uuid[])"},
      {"terminal_openings", "vm_id = ANY($1::uuid[])"},
      {"terminal_grants",
       "session_id IN (SELECT id FROM terminal_sessions WHERE vm_id = ANY($1::uuid[]))"},
      {"terminal_sessions_versions",
       "version_source_id IN (SELECT id FROM terminal_sessions WHERE vm_id = ANY($1::uuid[]))"},
      {"terminal_grants_versions",
       "version_source_id IN (SELECT id FROM terminal_grants WHERE session_id IN (SELECT id FROM terminal_sessions WHERE vm_id = ANY($1::uuid[])))"},
      {"ingress_endpoints", "vm_id = ANY($1::uuid[])"},
      {"ingress_endpoints_versions",
       "version_source_id IN (SELECT id FROM ingress_endpoints WHERE vm_id = ANY($1::uuid[]))"},
      {"ingress_sessions", "vm_id = ANY($1::uuid[])"},
      {"ingress_sessions_versions",
       "version_source_id IN (SELECT id FROM ingress_sessions WHERE vm_id = ANY($1::uuid[]))"},
      {"ingress_web_streams", "vm_id = ANY($1::uuid[])"},
      {"ingress_web_streams_versions",
       "version_source_id IN (SELECT id FROM ingress_web_streams WHERE vm_id = ANY($1::uuid[]))"},
      {"ingress_web_logins", "vm_id = ANY($1::uuid[])"},
      {"ingress_web_logins_versions",
       "version_source_id IN (SELECT id FROM ingress_web_logins WHERE vm_id = ANY($1::uuid[]))"},
      {"ingress_web_credentials", "vm_id = ANY($1::uuid[])"},
      {"ingress_web_credentials_versions",
       "version_source_id IN (SELECT id FROM ingress_web_credentials WHERE vm_id = ANY($1::uuid[]))"},
      {"ssh_keys", "user_id = $2"},
      {"ssh_keys_versions", "version_source_id IN (SELECT id FROM ssh_keys WHERE user_id = $2)"}
    ]

    sql =
      sections
      |> Enum.map(fn {table, where} ->
        "SELECT '#{table}' AS section, " <>
          "coalesce(jsonb_agg(row_to_json(t)::jsonb ORDER BY row_to_json(t)::text), '[]'::jsonb)::text AS rows " <>
          "FROM #{table} t WHERE #{where}"
      end)
      |> Enum.join(" UNION ALL ")

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(Marshall.Repo, sql <> " ORDER BY section", [vm_ids, member],
        log: false
      )

    Enum.map(rows, fn [section, aggregate] -> {section, aggregate} end)
  end

  # @cc [owner:ghuntley,label:verification] sharing-matrix-committed-cleanup
  # Committed teardown MUST delete exactly the fixture-owned rows in FK order.
  # Compute/access/terminal/endpoint history delegates to the reviewed cleanup;
  # ingress leases/credentials, the member key and the member user are local.
  @spec cleanup(t(), [VirtualMachine.t()]) :: :ok
  def cleanup(fixture, extra_vms \\ []) do
    vm_ids = Enum.map([fixture.vm | extra_vms], &Ecto.UUID.dump!(&1.id))
    member = Ecto.UUID.dump!(fixture.member.id)
    service = Ecto.UUID.dump!(fixture.service.id)

    delete = fn sql, params ->
      Ecto.Adapters.SQL.query!(Marshall.Repo, sql, params, log: false)
    end

    delete.(
      "DELETE FROM ingress_web_streams_versions WHERE version_source_id IN (SELECT id FROM ingress_web_streams WHERE vm_id = ANY($1::uuid[]))",
      [vm_ids]
    )

    delete.("DELETE FROM ingress_web_streams WHERE vm_id = ANY($1::uuid[])", [vm_ids])

    delete.(
      "DELETE FROM ingress_web_credentials_versions WHERE version_source_id IN (SELECT id FROM ingress_web_credentials WHERE vm_id = ANY($1::uuid[]))",
      [vm_ids]
    )

    delete.("DELETE FROM ingress_web_credentials WHERE vm_id = ANY($1::uuid[])", [vm_ids])

    delete.(
      "DELETE FROM ingress_web_logins_versions WHERE version_source_id IN (SELECT id FROM ingress_web_logins WHERE vm_id = ANY($1::uuid[]))",
      [vm_ids]
    )

    delete.("DELETE FROM ingress_web_logins WHERE vm_id = ANY($1::uuid[])", [vm_ids])

    delete.(
      "DELETE FROM ingress_sessions_versions WHERE version_source_id IN (SELECT id FROM ingress_sessions WHERE vm_id = ANY($1::uuid[]))",
      [vm_ids]
    )

    delete.("DELETE FROM ingress_sessions WHERE vm_id = ANY($1::uuid[])", [vm_ids])
    delete.("DELETE FROM ingress_services_versions WHERE version_source_id = $1", [service])
    delete.("DELETE FROM ingress_services WHERE id = $1", [service])

    delete.(
      "DELETE FROM ssh_keys_versions WHERE version_source_id IN (SELECT id FROM ssh_keys WHERE user_id = $1)",
      [member]
    )

    delete.("DELETE FROM ssh_keys WHERE user_id = $1", [member])
    delete.("DELETE FROM tokens WHERE subject = $1", ["user?id=" <> fixture.member.id])

    {:ok, _} = Marshall.CommittedFixtureCleanup.cleanup_compute(fixture.host.id, fixture.owner.id)
    delete.("DELETE FROM users WHERE id = $1", [member])
    :ok
  end
end
