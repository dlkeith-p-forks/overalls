defmodule Marshall.IngressHistoryFixture do
  @moduledoc "Full web/SSH ingress fixture: gateway, certificate, endpoint and browser flows."
  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{HostReports, Ledger, VirtualMachine}
  alias Marshall.Ingress
  alias Marshall.Ingress.{Endpoint, FleetCertificate, Token, WebCredential, WebStream}
  alias Marshall.TerminalFixtures

  # Struct-typed fields are widened to map() here: terminal_fixtures builds them
  # through generic host/credential construction whose success typing Dialyzer
  # cannot narrow to the concrete Ash resource structs.
  # Value types match Dialyzer's success typing of the constructed map exactly;
  # struct() is used where only "a struct" is inferable, term() where the
  # derived value is fully loose, and Issued.t() for the narrowed credential.
  @type t :: %{
          owner: map(),
          member: map(),
          member_token: String.t(),
          member_key: String.t(),
          machine: String.t(),
          vm: term(),
          host: struct(),
          pool: struct(),
          report: map(),
          connection: map(),
          credential: Marshall.Compute.Credentials.Issued.t(),
          epoch: non_neg_integer(),
          service: term(),
          service_token: String.t(),
          service_params: map(),
          dns_token: String.t(),
          endpoint: term(),
          label: term(),
          fingerprint: term(),
          certificate_expires_at: term(),
          certificate_generation: term(),
          token: String.t()
        }

  @doc "Create the single active wildcard for this test's zone (no installation)."
  # @cc [owner:ghuntley,label:verification] ingress-history-shared-wildcard
  # The fixture zone admits exactly one active wildcard; shared across generated
  # runs of one sandboxed test. Gateway installation proof stays per-run.
  @spec certificate(String.t(), pos_integer()) :: map()
  def certificate(fingerprint, generation) do
    zone = Application.fetch_env!(:marshall, :ingress_zone)
    expires_at = DateTime.add(Ledger.now(), 3600)

    certificate =
      FleetCertificate
      |> Ledger.create!(:enqueue, %{generation: generation, zone: zone})
      |> Ledger.update!(:bind_order, %{
        order_url: "https://ca.example.test/order/#{generation}",
        finalize_url: "https://ca.example.test/finalize/#{generation}",
        authorization_url: "https://ca.example.test/auth/#{generation}"
      })
      |> Ledger.update!(:finish_issued, %{
        chain_pem: "fixture-chain",
        fingerprint: fingerprint,
        expires_at: expires_at
      })
      |> Ledger.update!(:activate, %{})

    %{
      fingerprint: certificate.fingerprint,
      expires_at: certificate.expires_at,
      generation: certificate.generation
    }
  end

  @doc "Build the fixture stack through real public and internal actions."
  # @cc [owner:ghuntley,label:verification] ingress-history-real-fixture-stack
  # Fixture construction MUST use the real provision/report/service/endpoint/login
  # actions; only certificate installation and host reports stay synthetic.
  @spec new(map()) :: t()
  def new(certificate) do
    for host <- Ledger.read!(Marshall.Compute.Host),
        do: Ledger.update!(host, :configure, %{enabled: false})

    source = TerminalFixtures.terminal_fixture()
    member = Marshall.ComputeFixtures.user()
    {service_token, _} = Token.issue()

    service_params = %{
      name: "history-" <> Ash.UUID.generate(),
      role: :gateway,
      host_id: source.vm.host_id,
      token: service_token,
      addresses: ["192.0.2.9"]
    }

    {:ok, service} = Ingress.configure_service(service_params, actor: SystemActor.compute())

    {public, _} = :crypto.generate_key(:eddsa, :ed25519)
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, public::binary>>)

    {:ok, _} =
      Ingress.publish_host_key(%{token: service_token, public_key: key},
        actor: SystemActor.compute()
      )

    {dns_token, _} = Token.issue()

    {:ok, _dns} =
      Ingress.configure_service(
        %{name: "history-dns-" <> Ash.UUID.generate(), role: :dns, token: dns_token},
        actor: SystemActor.compute()
      )

    [endpoint] = Ledger.read!(Endpoint, vm_id: source.vm.id)

    {:ok, endpoint} =
      Ingress.configure_endpoint(
        %{
          vm_id: source.vm.id,
          expected_revision: endpoint.policy_revision,
          primary_port: 8080,
          visibility: :private
        },
        actor: source.owner
      )

    {:ok, _} =
      Marshall.Access.set_access(
        %{
          vm_id: source.vm.id,
          email: to_string(member.email),
          role: :web,
          idempotency_key: Ash.UUID.generate()
        },
        actor: source.owner
      )

    public_key =
      "ssh-ed25519 " <>
        Base.encode64(<<11::32, "ssh-ed25519", 32::32, :crypto.strong_rand_bytes(32)::binary>>)

    {:ok, _} = Marshall.SSH.add_key(%{public_key: public_key}, actor: member)

    Map.merge(source, %{
      member: member,
      member_token: TerminalFixtures.user_token(member),
      member_key: public_key,
      service: service,
      service_token: service_token,
      service_params: service_params,
      dns_token: dns_token,
      endpoint: endpoint,
      label: endpoint.label,
      fingerprint: certificate.fingerprint,
      certificate_expires_at: certificate.expires_at,
      certificate_generation: certificate.generation
    })
  end

  @doc "Exchange a complete browser login flow for the member's given login token."
  @spec cookie(t(), String.t(), non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  def cookie(c, member_token, app_port) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.encode16(:crypto.hash(:sha256, state), case: :lower)

    with {:ok, started} <-
           Ingress.begin_web_login(
             %{
               service_token: c.service_token,
               label: c.label,
               app_port: app_port,
               state_digest: digest
             },
             actor: SystemActor.compute()
           ),
         {:ok, approved} <-
           Ingress.authorize_web_login(%{ticket: started.ticket, login_token: member_token},
             actor: c.member
           ),
         {:ok, exchanged} <-
           Ingress.exchange_web_login(
             %{
               service_token: c.service_token,
               ticket: started.ticket,
               code: approved.code,
               state: state
             },
             actor: SystemActor.compute()
           ) do
      {:ok, exchanged.cookie}
    end
  end

  @spec open_web(t(), String.t() | nil, non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def open_web(c, cookie, app_port),
    do:
      Ingress.open_web(
        %{service_token: c.service_token, label: c.label, app_port: app_port, cookie: cookie},
        actor: SystemActor.compute()
      )

  @spec open_ssh(t(), :owner | :member) :: {:ok, map()} | {:error, term()}
  def open_ssh(c, :owner),
    do: open_ssh_with_key(c, owner_key(c))

  def open_ssh(c, :member),
    do: open_ssh_with_key(c, c.member_key)

  defp open_ssh_with_key(c, public_key),
    do:
      Ingress.open_ssh(
        %{service_token: c.service_token, public_key: public_key, label: c.label},
        actor: SystemActor.compute()
      )

  @doc "Register and return a fresh owner SSH key."
  @spec owner_key(t()) :: String.t()
  def owner_key(c) do
    public =
      "ssh-ed25519 " <>
        Base.encode64(<<11::32, "ssh-ed25519", 32::32, :crypto.strong_rand_bytes(32)::binary>>)

    {:ok, _} = Marshall.SSH.add_key(%{public_key: public}, actor: c.owner)
    public
  end

  @spec sign_out(User.t(), String.t()) :: :ok
  def sign_out(member, token) do
    conn =
      Plug.Test.conn(:get, "/sign-out")
      |> Plug.Test.init_test_session(%{"user_token" => token})
      |> Plug.Conn.assign(:current_user, member)
      |> Phoenix.Controller.fetch_flash()
      |> MarshallWeb.AuthController.sign_out(%{})

    true = conn.status == 302
    :ok
  end

  @spec renew_web(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def renew_web(c, ticket),
    do:
      Ingress.renew_web(%{service_token: c.service_token, stream_token: ticket},
        actor: SystemActor.compute()
      )

  @spec rotate(t()) :: t()
  def rotate(c) do
    {token, _} = Token.issue()

    {:ok, service} =
      Ingress.configure_service(%{c.service_params | token: token}, actor: SystemActor.compute())

    {public, _} = :crypto.generate_key(:eddsa, :ed25519)
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, public::binary>>)

    {:ok, _} =
      Ingress.publish_host_key(%{token: token, public_key: key}, actor: SystemActor.compute())

    %{c | service: service, service_token: token}
  end

  @spec acknowledge_certificate(t()) :: {:ok, term()} | {:error, term()}
  def acknowledge_certificate(c),
    do:
      Ingress.acknowledge_fleet_certificate(
        %{
          service_token: c.service_token,
          generation: c.certificate_generation,
          fingerprint: c.fingerprint
        },
        actor: SystemActor.compute()
      )

  @spec route_report(t()) :: {:ok, map()} | {:error, term()}
  def route_report(c) do
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    [service] = Ledger.read!(Marshall.Ingress.Service, id: c.service.id)

    Ingress.report_ready_route(
      %{
        service_token: c.service_token,
        service_generation: service.generation,
        vm_id: vm.id,
        placement_id: vm.current_placement_id,
        execution_epoch: vm.execution_epoch,
        generation: vm.generation,
        certificate_fingerprint: c.fingerprint,
        certificate_expires_at: c.certificate_expires_at
      },
      actor: SystemActor.compute()
    )
  end

  @spec renew_ssh(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def renew_ssh(c, ticket),
    do:
      Ingress.renew_ssh(%{service_token: c.service_token, session_token: ticket},
        actor: SystemActor.compute()
      )

  @spec close(t(), atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def close(c, :web, ticket),
    do:
      Ingress.close_web(%{service_token: c.service_token, stream_token: ticket},
        actor: SystemActor.compute()
      )

  def close(c, :ssh, ticket),
    do:
      Ingress.close_ssh(%{service_token: c.service_token, session_token: ticket},
        actor: SystemActor.compute()
      )

  @doc "Current role decision independent from the subject under test."
  @spec configure_endpoint(t(), non_neg_integer(), :private | :public) ::
          {:ok, map()} | {:error, term()}
  def configure_endpoint(c, port, visibility) do
    [endpoint] = Ledger.read!(Endpoint, vm_id: c.vm.id)

    Ingress.configure_endpoint(
      %{
        vm_id: c.vm.id,
        expected_revision: endpoint.policy_revision,
        primary_port: port,
        visibility: visibility
      },
      actor: c.owner
    )
  end

  @doc "Publish the DNS snapshot for the shared configured zone."
  @spec publish(t()) :: {:ok, map()} | {:error, term()}
  def publish(c),
    do:
      Ingress.dns_snapshot(
        %{token: c.dns_token, zone: Application.fetch_env!(:marshall, :ingress_zone)},
        actor: SystemActor.compute()
      )

  @doc "Current route projection for this fixture's label."
  @spec current_route(t()) :: {:ok, map()} | {:error, term()}
  def current_route(c),
    do: Ingress.current_route(%{label: c.label}, actor: SystemActor.compute())

  @spec expire_stream(String.t(), DateTime.t(), atom()) :: :ok
  def expire_stream(id, at, :web), do: backdate_stream(id, at)
  def expire_stream(id, at, :ssh), do: backdate_session(id, at)

  @doc "Current member login token minting, matching real browser re-login."
  @spec fresh_login(t()) :: String.t()
  def fresh_login(c), do: Marshall.TerminalFixtures.user_token(c.member)

  @spec revoke_cookie(String.t()) :: {:ok, WebCredential.t()}
  def revoke_cookie(cookie) do
    {:ok, hash} = Token.digest(cookie, :web_cookie)
    [credential] = Ledger.read!(WebCredential, token_hash: hash)
    {:ok, Ledger.update!(credential, :revoke, %{revoked_at: Ledger.now()})}
  end

  @spec revoke_cookie_id(term()) :: :ok
  def revoke_cookie_id(credential) do
    Ledger.update!(credential, :revoke, %{revoked_at: Ledger.now()})
    :ok
  end

  @spec role(t(), User.t(), atom()) :: :ok
  def role(c, member, role) do
    {:ok, _} =
      Marshall.Access.set_access(
        %{
          vm_id: c.vm.id,
          email: to_string(member.email),
          role: role,
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.owner
      )

    :ok
  end

  @spec stop_intent(t()) :: :ok
  def stop_intent(c) do
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    Ledger.intent!(vm, %{desired_state: :stopped, generation: vm.generation + 1})
    :ok
  end

  @spec epoch_bump(t()) :: :ok
  def epoch_bump(c) do
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    Ledger.intent!(vm, %{desired_state: vm.desired_state, generation: vm.generation + 1})
    :ok
  end

  @spec backdate_stream(String.t(), DateTime.t()) :: :ok
  def backdate_stream(id, at) do
    [stream] = Ledger.read!(WebStream, id: id)
    Ledger.update!(stream, :renew, %{expires_at: at})
    :ok
  end

  @spec backdate_session(String.t(), DateTime.t()) :: :ok
  def backdate_session(id, at) do
    [session] = Ledger.read!(Marshall.Ingress.Session, id: id)
    Ledger.update!(session, :renew, %{expires_at: at})
    :ok
  end

  @spec backdate_route(String.t()) :: :ok
  def backdate_route(id) do
    [route] = Ledger.read!(Marshall.Ingress.Route, id: id)

    Ledger.update!(route, :refresh, %{
      expires_at: DateTime.add(Ledger.now(), -1),
      revision: route.revision
    })

    :ok
  end

  @doc "Refresh host evidence through the real report ingestion path."
  @spec fresh_report(t() | map(), non_neg_integer()) :: :ok
  def fresh_report(c, sequence) do
    {:ok, :ok} =
      HostReports.ingest(c.host.id, c.connection.epoch, %{
        c.report
        | sequence: sequence + 10,
          sampled_at: Ledger.now()
      })

    :ok
  end

  # @cc [owner:ghuntley,label:verification] ingress-committed-fixture-scope
  # Committed fixtures (shared across peer nodes) build public web ingress only:
  # no certificate, DNS identity, member sharing or browser credential, so their
  # teardown footprint stays enumerated. Teardown MUST delete only this
  # fixture's service rows before compute cleanup and restore the inventory.
  @spec new_public() :: map()
  def new_public do
    source = TerminalFixtures.terminal_fixture()
    {service_token, _} = Token.issue()

    service_params = %{
      name: "distributed-" <> Ash.UUID.generate(),
      role: :gateway,
      host_id: source.vm.host_id,
      token: service_token,
      addresses: ["192.0.2.9"]
    }

    {:ok, service} = Ingress.configure_service(service_params, actor: SystemActor.compute())

    {public, _} = :crypto.generate_key(:eddsa, :ed25519)
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, public::binary>>)

    {:ok, _} =
      Ingress.publish_host_key(%{token: service_token, public_key: key},
        actor: SystemActor.compute()
      )

    [endpoint] = Ledger.read!(Endpoint, vm_id: source.vm.id)

    {:ok, endpoint} =
      Ingress.configure_endpoint(
        %{
          vm_id: source.vm.id,
          expected_revision: endpoint.policy_revision,
          primary_port: 8080,
          visibility: :public
        },
        actor: source.owner
      )

    Map.merge(source, %{
      service: service,
      service_token: service_token,
      service_params: service_params,
      endpoint: endpoint,
      label: endpoint.label
    })
  end

  @spec cleanup_public(map()) :: :ok
  def cleanup_public(fixture) do
    id = Ecto.UUID.dump!(fixture.service.id)

    for statement <- [
          "DELETE FROM ingress_web_streams_versions WHERE version_source_id IN (SELECT id FROM ingress_web_streams WHERE service_id=$1)",
          "DELETE FROM ingress_web_streams WHERE service_id=$1",
          "DELETE FROM ingress_services_versions WHERE version_source_id=$1",
          "DELETE FROM ingress_services WHERE id=$1"
        ],
        do: Marshall.Repo.query!(statement, [id], log: false)

    {:ok, _} = Marshall.CommittedFixtureCleanup.cleanup_compute(fixture.host.id, fixture.owner.id)
    :ok
  end

  @doc "Committed web stream rows for a service, as any peer reads them."
  @spec stream_rows(String.t()) :: [WebStream.t()]
  def stream_rows(service_id), do: Ledger.read!(WebStream, service_id: service_id)

  @doc "Error extraction: the fixed ingress reason atom from any error wrapper."
  @spec reason(term()) :: atom() | :ok
  def reason({:ok, _}), do: :ok
  def reason({:error, %Ash.Error.Invalid{errors: [%{reason: reason} | _]}}), do: reason
  def reason({:error, %{reason: reason}}), do: reason
  def reason({:error, other}) when is_atom(other), do: other

  @doc "Committed service generation as any peer reads it."
  @spec service_generation(map()) :: pos_integer()
  def service_generation(c) do
    [service] = Ledger.read!(Marshall.Ingress.Service, id: c.service.id)
    service.generation
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  def query(sql, params \\ []),
    do: Ecto.Adapters.SQL.query!(Marshall.Repo, sql, params, log: false)

  # @cc [owner:ghuntley,label:verification] ingress-rotation-gate
  # The distributed rotation gate MUST pause a real service-generation update
  # mid-transaction via a trigger advisory lock, never a fabricated outcome, and
  # removal MUST leave production tables and functions untouched.
  @spec install_rotation_gate(String.t(), pos_integer()) :: :ok
  def install_rotation_gate(id, gate) do
    id = Ecto.UUID.cast!(id)
    name = "ingress_rotation_gate_" <> String.replace(id, "-", "_")

    query("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.id = TG_ARGV[0]::uuid AND NEW.generation <> OLD.generation THEN
        PERFORM pg_advisory_xact_lock(TG_ARGV[1]::bigint);
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    query("""
    CREATE TRIGGER #{name} BEFORE UPDATE ON ingress_services
    FOR EACH ROW EXECUTE FUNCTION #{name}('#{id}', '#{gate}')
    """)

    :ok
  end

  @spec remove_rotation_gate(String.t()) :: :ok
  def remove_rotation_gate(id) do
    name = "ingress_rotation_gate_" <> String.replace(Ecto.UUID.cast!(id), "-", "_")
    query("DROP TRIGGER IF EXISTS #{name} ON ingress_services")
    query("DROP FUNCTION IF EXISTS #{name}()")
    :ok
  end
end
