defmodule Marshall.SharingRevocationFixture do
  @moduledoc """
  Committed fixture for revoke-versus-renewal serialization schedules: one VM
  shared with a member, a live Audi SSH session, a live private web stream, and
  database write gates that pause the real renewal or revocation write while
  its transaction holds the VM row lock. Peers never reuse the coordinator
  connection; gates acquire no production locks.
  """

  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress
  alias Marshall.Repo

  import ExUnit.Assertions

  @type surface :: :ssh | :web
  @type boundary :: :revoke | :renewal
  @type outcome :: Marshall.JobHistoryFixture.outcome()

  # @cc [owner:ghuntley,label:verification] sharing-revoke-remote-completion
  # Only a peer-side completion envelope proves a remote mutation stopped;
  # transport failures require stopping the uncertain peer before cleanup.
  @spec invoke(module(), atom(), [term()]) :: {:completed, outcome()}
  defdelegate invoke(module, function, arguments), to: Marshall.JobHistoryFixture

  @type context :: %{
          host_id: String.t(),
          vm_id: String.t(),
          owner: Marshall.Accounts.User.t(),
          owner_id: String.t(),
          member: Marshall.Accounts.User.t(),
          member_id: String.t(),
          member_email: String.t(),
          member_public: String.t(),
          key_id: String.t(),
          service_id: String.t(),
          service_token: String.t(),
          label: String.t(),
          member_token: String.t(),
          ssh_ticket: String.t(),
          ssh_session_id: String.t(),
          web_ticket: String.t(),
          web_stream_id: String.t()
        }

  @type snapshot :: %{
          grant_active: boolean(),
          changes: non_neg_integer(),
          ssh_expires_at: DateTime.t(),
          web_expires_at: DateTime.t()
        }

  # @cc [owner:ghuntley,label:verification] sharing-revoke-committed-fixture
  # Every admission below MUST come from the real public/gateway actions against
  # committed PostgreSQL rows. Session and stream identities are returned for
  # exact cleanup; the fixture MUST NOT fabricate lease rows.
  @spec setup() :: context()
  def setup do
    # Disable leftovers from any earlier failed schedule so admission always
    # lands on this fixture's fresh committed host.
    for host <- Ledger.read!(Marshall.Compute.Host),
        do: Ledger.update!(host, :configure, %{enabled: false})

    fixture = Marshall.TerminalFixtures.terminal_fixture()
    member = Marshall.ComputeFixtures.user()
    member_public = Marshall.SharingSurfacesFixture.key_text()
    {:ok, key} = Marshall.SSH.add_key(%{public_key: member_public}, actor: member)
    member_token = Marshall.TerminalFixtures.user_token(member)
    {service_token, _} = Ingress.Token.issue()

    {:ok, service} =
      Ingress.configure_service(
        %{
          name: "sharing-revoke-" <> Ash.UUID.generate(),
          role: :gateway,
          host_id: fixture.vm.host_id,
          token: service_token,
          addresses: ["192.0.2.17"]
        },
        actor: SystemActor.compute()
      )

    {:ok, _} =
      Ingress.publish_host_key(
        %{token: service_token, public_key: Marshall.SharingSurfacesFixture.key_text()},
        actor: SystemActor.compute()
      )

    [endpoint] = Ledger.read!(Ingress.Endpoint, vm_id: fixture.vm.id)

    {:ok, _} =
      Ingress.configure_endpoint(
        %{
          vm_id: fixture.vm.id,
          expected_revision: endpoint.policy_revision,
          primary_port: 8080,
          visibility: :private
        },
        actor: fixture.owner
      )

    assert {:ok, _} = Marshall.TerminalFixtures.grant(fixture, member, :operator)

    {:ok, ssh} =
      Ingress.open_ssh(
        %{service_token: service_token, public_key: member_public, label: endpoint.label},
        actor: SystemActor.compute()
      )

    {:ok, cookie} =
      Marshall.SharingSurfacesFixture.approve_web(%{
        service_token: service_token,
        label: endpoint.label,
        member: member,
        member_token: member_token
      })

    {:ok, web} =
      Ingress.open_web(
        %{service_token: service_token, label: endpoint.label, app_port: 0, cookie: cookie},
        actor: SystemActor.compute()
      )

    %{
      host_id: fixture.vm.host_id,
      vm_id: fixture.vm.id,
      owner: fixture.owner,
      owner_id: fixture.owner.id,
      member: member,
      member_id: member.id,
      member_email: to_string(member.email),
      member_public: member_public,
      key_id: key.id,
      service_id: service.id,
      service_token: service_token,
      label: endpoint.label,
      member_token: member_token,
      ssh_ticket: ssh.ticket,
      ssh_session_id: ssh.binding.session_id,
      web_ticket: web.ticket,
      web_stream_id: web.binding.session_id
    }
  end

  # @cc [owner:ghuntley,label:verification] sharing-revoke-real-action-gates
  # Gates MUST pause only the selected row's actual write before it commits, on
  # an exact fixture identity; they acquire no production row locks. Removal
  # MUST drop both trigger and function.
  @spec install_gate(boundary(), context(), pos_integer()) :: :ok
  def install_gate(:revoke, context, gate) do
    name = name("revoke", context.vm_id)

    query("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.vm_id = TG_ARGV[0]::uuid THEN
        PERFORM pg_advisory_xact_lock(TG_ARGV[1]::bigint);
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    query("""
    CREATE TRIGGER #{name} BEFORE INSERT ON access_changes
    FOR EACH ROW EXECUTE FUNCTION #{name}('#{Ecto.UUID.cast!(context.vm_id)}', '#{gate}')
    """)

    :ok
  end

  def install_gate(:renewal, context, gate) do
    for {table, id} <- [
          {"ingress_sessions", context.ssh_session_id},
          {"ingress_web_streams", context.web_stream_id}
        ] do
      name = name("renewal", id)

      query("""
      CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.id = TG_ARGV[0]::uuid THEN
          PERFORM pg_advisory_xact_lock(TG_ARGV[1]::bigint);
        END IF;
        RETURN NEW;
      END;
      $$
      """)

      query("""
      CREATE TRIGGER #{name} BEFORE UPDATE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION #{name}('#{Ecto.UUID.cast!(id)}', '#{gate}')
      """)
    end

    :ok
  end

  @spec remove_gates(boundary(), context()) :: :ok
  def remove_gates(:revoke, context) do
    query("DROP TRIGGER IF EXISTS #{name("revoke", context.vm_id)} ON access_changes")
    query("DROP FUNCTION IF EXISTS #{name("revoke", context.vm_id)}()")
    :ok
  end

  def remove_gates(:renewal, context) do
    for {table, id} <- [
          {"ingress_sessions", context.ssh_session_id},
          {"ingress_web_streams", context.web_stream_id}
        ] do
      query("DROP TRIGGER IF EXISTS #{name("renewal", id)} ON #{table}")
      query("DROP FUNCTION IF EXISTS #{name("renewal", id)}()")
    end

    :ok
  end

  @spec revoke(context()) :: {:ok, term()} | {:error, term()}
  def revoke(context),
    do:
      Marshall.Access.set_access(
        %{
          vm_id: context.vm_id,
          email: context.member_email,
          role: :revoked,
          idempotency_key: Ash.UUID.generate()
        },
        actor: context.owner
      )

  @spec renew(context(), surface()) :: {:ok, term()} | {:error, term()}
  def renew(context, :ssh),
    do:
      Ingress.renew_ssh(
        %{service_token: context.service_token, session_token: context.ssh_ticket},
        actor: SystemActor.compute()
      )

  def renew(context, :web),
    do:
      Ingress.renew_web(
        %{service_token: context.service_token, stream_token: context.web_ticket},
        actor: SystemActor.compute()
      )

  @spec open_again(context(), surface()) :: {:ok, term()} | {:error, term()}
  def open_again(context, :ssh),
    do:
      Ingress.open_ssh(
        %{
          service_token: context.service_token,
          public_key: context.member_public,
          label: context.label
        },
        actor: SystemActor.compute()
      )

  def open_again(context, :web),
    do:
      Marshall.SharingSurfacesFixture.approve_web(%{
        service_token: context.service_token,
        label: context.label,
        member: context.member,
        member_token: context.member_token
      })

  @spec snapshot(context()) :: snapshot()
  def snapshot(context) do
    %{rows: [[active]]} =
      query(
        "SELECT count(*) = 1 FROM access_grants WHERE vm_id=$1 AND user_id=$2 AND archived_at IS NULL",
        [
          Ecto.UUID.dump!(context.vm_id),
          Ecto.UUID.dump!(context.member_id)
        ]
      )

    %{rows: [[changes]]} =
      query("SELECT count(*) FROM access_changes WHERE vm_id=$1 AND user_id=$2", [
        Ecto.UUID.dump!(context.vm_id),
        Ecto.UUID.dump!(context.member_id)
      ])

    %{rows: [[ssh_expires]]} =
      query("SELECT expires_at FROM ingress_sessions WHERE id=$1", [
        Ecto.UUID.dump!(context.ssh_session_id)
      ])

    %{rows: [[web_expires]]} =
      query("SELECT expires_at FROM ingress_web_streams WHERE id=$1", [
        Ecto.UUID.dump!(context.web_stream_id)
      ])

    %{
      grant_active: active,
      changes: changes,
      ssh_expires_at: ssh_expires,
      web_expires_at: web_expires
    }
  end

  # @cc [owner:ghuntley,label:verification] sharing-revoke-fixture-teardown
  # Cleanup MUST remove exactly the fixture-created rows by identity, in foreign
  # key order: leases, web credentials/logins, the gateway, keys, then the
  # compute fixture (which owns access changes and the owner), then the member.
  # Every historical row outside this fixture MUST survive.
  @spec cleanup(context()) :: :ok
  def cleanup(context) do
    vm = Ecto.UUID.dump!(context.vm_id)

    for {table, id} <- [
          {"ingress_sessions_versions", context.ssh_session_id},
          {"ingress_sessions", context.ssh_session_id},
          {"ingress_web_streams_versions", context.web_stream_id},
          {"ingress_web_streams", context.web_stream_id}
        ] do
      if String.ends_with?(table, "_versions") do
        query("DELETE FROM #{table} WHERE version_source_id=$1", [Ecto.UUID.dump!(id)])
      else
        query("DELETE FROM #{table} WHERE id=$1", [Ecto.UUID.dump!(id)])
      end
    end

    query(
      "DELETE FROM ingress_web_credentials_versions WHERE version_source_id IN (SELECT id FROM ingress_web_credentials WHERE vm_id=$1)",
      [vm]
    )

    query("DELETE FROM ingress_web_credentials WHERE vm_id=$1", [vm])

    query(
      "DELETE FROM ingress_web_logins_versions WHERE version_source_id IN (SELECT id FROM ingress_web_logins WHERE vm_id=$1)",
      [vm]
    )

    query("DELETE FROM ingress_web_logins WHERE vm_id=$1", [vm])

    query("DELETE FROM ingress_services_versions WHERE version_source_id=$1", [
      Ecto.UUID.dump!(context.service_id)
    ])

    query("DELETE FROM ingress_services WHERE id=$1", [Ecto.UUID.dump!(context.service_id)])

    {:ok, _} =
      Marshall.CommittedFixtureCleanup.cleanup_compute(context.host_id, context.owner_id)

    member = Ecto.UUID.dump!(context.member_id)

    query(
      "DELETE FROM ssh_keys_versions WHERE version_source_id IN (SELECT id FROM ssh_keys WHERE user_id=$1)",
      [member]
    )

    query("DELETE FROM ssh_keys WHERE user_id=$1", [member])
    query("DELETE FROM tokens WHERE subject=$1", ["user?id=" <> context.member_id])
    query("DELETE FROM users WHERE id=$1", [member])
    :ok
  end

  # @cc [owner:ghuntley,label:verification;concurrency] sharing-revoke-read-facts
  # Read-only facts MUST use the database clock and exact fixture identities.
  # Lease liveness and TTL bounds are evaluated in SQL so a later authority
  # denial cannot be confused with expiry.
  @spec live?(context(), surface()) :: boolean()
  def live?(context, surface) do
    table = if surface == :ssh, do: "ingress_sessions", else: "ingress_web_streams"
    id = if surface == :ssh, do: context.ssh_session_id, else: context.web_stream_id

    %{rows: [[live]]} =
      query(
        "SELECT closed_at IS NULL AND expires_at > clock_timestamp() FROM #{table} WHERE id=$1",
        [Ecto.UUID.dump!(id)]
      )

    live
  end

  @spec within_ttl?(context(), surface()) :: boolean()
  def within_ttl?(context, surface) do
    table = if surface == :ssh, do: "ingress_sessions", else: "ingress_web_streams"
    id = if surface == :ssh, do: context.ssh_session_id, else: context.web_stream_id

    %{rows: [[bounded]]} =
      query(
        "SELECT expires_at <= clock_timestamp() + interval '30 seconds' AND expires_at > clock_timestamp() FROM #{table} WHERE id=$1",
        [Ecto.UUID.dump!(id)]
      )

    bounded
  end

  @spec expires_at(context(), surface()) :: DateTime.t()
  def expires_at(context, surface) do
    table = if surface == :ssh, do: "ingress_sessions", else: "ingress_web_streams"
    id = if surface == :ssh, do: context.ssh_session_id, else: context.web_stream_id

    %{rows: [[expires]]} =
      query("SELECT expires_at FROM #{table} WHERE id=$1", [Ecto.UUID.dump!(id)])

    expires
  end

  @spec extended?(context(), surface(), DateTime.t()) :: boolean()
  def extended?(context, surface, before) do
    table = if surface == :ssh, do: "ingress_sessions", else: "ingress_web_streams"
    id = if surface == :ssh, do: context.ssh_session_id, else: context.web_stream_id

    %{rows: [[extended]]} =
      query("SELECT expires_at > $1 FROM #{table} WHERE id=$2", [
        before,
        Ecto.UUID.dump!(id)
      ])

    extended
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  def query(sql, params \\ []),
    do: Ecto.Adapters.SQL.query!(Repo, sql, params, log: false)

  @spec name(String.t(), String.t()) :: String.t()
  defp name(kind, id),
    do: "sharing_revocation_gate_" <> kind <> "_" <> String.replace(id, "-", "_")
end
