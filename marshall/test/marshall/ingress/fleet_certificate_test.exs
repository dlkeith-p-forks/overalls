defmodule Marshall.Ingress.FleetCertificateTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Accounts.AdminEvent
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress

  alias Marshall.Ingress.{
    FleetCertificate,
    FleetCertificateAccount,
    FleetCertificateInstallation,
    Token
  }

  @certificate Path.expand("../../fixtures/tls/localhost.pem", __DIR__)
  @key Path.expand("../../fixtures/tls/localhost.key", __DIR__)
  @ca Path.expand("../../fixtures/tls/ca.pem", __DIR__)

  # @cc [owner:ghuntley,label:verification;recovery] generated-certificate-activation-order
  # Delayed issued generations MUST fail activation after any newer generation
  # exists. Refusal MUST preserve the active certificate and audit rows; only
  # the latest issued generation may retire its predecessor and become active.
  @tag :hegel_case_sandbox
  property "generated delayed certificate jobs never activate an older generation",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    previous_acme = Application.get_env(:marshall, :fleet_acme)
    Hegel.on_cleanup(fn -> restore_env(:fleet_acme, previous_acme) end)

    count = draw("count", integer(1..3))
    order = draw("order", shuffle(Enum.to_list(1..count)))
    newer_status = draw("newer_status", member_of([:pending, :failed, :issued]))
    retries = draw("retries", integer(1..3))
    zone = "#{Ash.UUID.generate()}.example.test"
    base = System.unique_integer([:positive, :monotonic]) * 10

    Application.put_env(:marshall, :fleet_acme, %{
      zone: zone,
      directory: "https://acme.example.test/directory",
      issuer_ca_file: @ca,
      roots_file: @ca,
      nameservers: [{{192, 0, 2, 1}, 53}, {{192, 0, 2, 2}, 53}],
      accept_terms: true
    })

    incumbent = issued_certificate(base, zone)
    assert :ok = Marshall.Ingress.CertificateAuthority.step(incumbent.id)

    delayed = Map.new(1..count, &{&1, issued_certificate(base + &1, zone)})

    newer =
      Ledger.create!(FleetCertificate, :enqueue, %{generation: base + count + 1, zone: zone})

    newer =
      case newer_status do
        :pending -> newer
        :failed -> Ledger.update!(newer, :fail, %{})
        :issued -> issue_certificate(newer)
      end

    before = certificate_projection(zone)

    for index <- order, _ <- 1..retries do
      assert {:error, :invalid_state} =
               Marshall.Ingress.CertificateAuthority.step(delayed[index].id)

      assert certificate_projection(zone) == before
    end

    if newer_status == :issued do
      assert :ok = Marshall.Ingress.CertificateAuthority.step(newer.id)
      assert [%{id: active_id}] = Ledger.read!(FleetCertificate, zone: zone, status: :active)
      assert active_id == newer.id
      assert [%{status: :retired}] = Ledger.read!(FleetCertificate, id: incumbent.id)
    else
      assert [%{id: active_id}] = Ledger.read!(FleetCertificate, zone: zone, status: :active)
      assert active_id == incumbent.id
    end

    after_activation = certificate_projection(zone)

    if newer_status == :issued do
      for _ <- 1..retries do
        assert :ok = Marshall.Ingress.CertificateAuthority.step(newer.id)
        assert certificate_projection(zone) == after_activation
      end
    end

    for index <- Enum.reverse(order) do
      assert {:error, :invalid_state} =
               Marshall.Ingress.CertificateAuthority.step(delayed[index].id)

      assert certificate_projection(zone) == after_activation
    end
  end

  @spec issued_certificate(pos_integer(), String.t()) :: FleetCertificate.t()
  # @cc [owner:ghuntley,label:verification;recovery] fleet-generation-per-zone
  # Generations restart per ingress zone. After a zone rename the new zone MUST
  # allocate generation 1 and each gateway MUST record its acknowledgement even
  # though the retired zone kept generation 1 and its installations.
  test "a renamed ingress zone reuses generation 1 for certificates and installations" do
    old_zone = "old-#{Ash.UUID.generate()}.example.test"
    new_zone = "new-#{Ash.UUID.generate()}.example.test"
    host_id = Ash.UUID.generate()
    service_id = Ash.UUID.generate()

    issued_certificate(1, old_zone)
    assert %{generation: 1} = issued_certificate(1, new_zone)

    for {zone, fingerprint} <- [
          {old_zone, String.duplicate("a", 64)},
          {new_zone, String.duplicate("b", 64)}
        ] do
      Ledger.create!(FleetCertificateInstallation, :record, %{
        host_id: host_id,
        service_id: service_id,
        service_generation: 1,
        zone: zone,
        generation: 1,
        fingerprint: fingerprint
      })
    end

    assert [%{fingerprint: "bbbb" <> _}] =
             Ledger.read!(FleetCertificateInstallation, host_id: host_id, zone: new_zone)

    duplicate =
      try do
        Ledger.create!(FleetCertificateInstallation, :record, %{
          host_id: host_id,
          service_id: service_id,
          service_generation: 1,
          zone: new_zone,
          generation: 1,
          fingerprint: String.duplicate("c", 64)
        })

        :created
      rescue
        _ -> :refused
      end

    assert duplicate == :refused
  end

  defp issued_certificate(generation, zone) do
    Ledger.create!(FleetCertificate, :enqueue, %{generation: generation, zone: zone})
    |> issue_certificate()
  end

  @spec issue_certificate(FleetCertificate.t()) :: FleetCertificate.t()
  defp issue_certificate(row) do
    row
    |> Ledger.update!(:bind_order, %{
      order_url: "https://ca.example.test/order/#{row.generation}",
      finalize_url: "https://ca.example.test/finalize/#{row.generation}",
      authorization_url: "https://ca.example.test/auth/#{row.generation}"
    })
    |> Ledger.update!(:finish_issued, %{
      chain_pem: "fixture-chain",
      fingerprint: String.duplicate("a", 64),
      expires_at: DateTime.add(Ledger.now(), 3600)
    })
  end

  @type certificate_snapshot ::
          {String.t(), pos_integer(), atom(), binary() | nil, DateTime.t()}

  @spec certificate_projection(String.t()) ::
          {[certificate_snapshot()], [String.t()]}
  defp certificate_projection(zone) do
    rows = Ledger.read!(FleetCertificate, zone: zone)
    ids = MapSet.new(rows, & &1.id)

    versions =
      Ledger.read!(FleetCertificate.Version)
      |> Enum.filter(&MapSet.member?(ids, &1.version_source_id))
      |> Enum.map(& &1.id)
      |> Enum.sort()

    {Enum.sort(
       Enum.map(rows, &{&1.id, &1.generation, &1.status, &1.encrypted_chain_pem, &1.updated_at})
     ), versions}
  end

  defmodule LostOrderReply do
    @behaviour Plug
    @type options :: {pid(), pid(), pid()}
    @spec init(options()) :: options()
    @impl true
    def init(options), do: options

    @spec call(Plug.Conn.t(), options()) :: Plug.Conn.t()
    @impl true
    def call(conn, {origin_ref, counter, owner}) do
      origin = Agent.get(origin_ref, & &1)

      case {conn.method, conn.request_path} do
        {"GET", "/dir"} ->
          Plug.Conn.send_resp(
            conn,
            200,
            Jason.encode!(%{
              newNonce: origin <> "/nonce",
              newAccount: origin <> "/account",
              newOrder: origin <> "/order"
            })
          )

        {"HEAD", "/nonce"} ->
          conn
          |> Plug.Conn.put_resp_header("replay-nonce", "AA")
          |> Plug.Conn.send_resp(204, "")

        {"POST", "/account"} ->
          conn
          |> Plug.Conn.put_resp_header("location", origin <> "/account/1")
          |> Plug.Conn.send_resp(201, ~s({"status":"valid"}))

        {"POST", "/order"} ->
          Agent.update(counter, &(&1 + 1))

          conn
          |> Plug.Conn.register_before_send(fn _ ->
            send(owner, :order_response_dropped)
            Process.exit(self(), :kill)
          end)
          |> Plug.Conn.send_resp(201, "")

        _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end
  end

  test "elevated administrator rotation allocates one audited generation under the renewal lock" do
    zone = "apps.example.test"
    previous_zone = Application.get_env(:marshall, :ingress_zone)
    previous_acme = Application.get_env(:marshall, :fleet_acme)
    Application.put_env(:marshall, :ingress_zone, zone)
    Application.put_env(:marshall, :fleet_acme, %{zone: zone})

    on_exit(fn ->
      restore_env(:ingress_zone, previous_zone)
      restore_env(:fleet_acme, previous_acme)
    end)

    current =
      Ledger.create!(FleetCertificate, :enqueue, %{generation: 1, zone: zone})
      |> Ledger.update!(:bind_order, %{
        order_url: "https://ca.example.test/order/1",
        finalize_url: "https://ca.example.test/finalize/1",
        authorization_url: "https://ca.example.test/auth/1"
      })
      |> Ledger.update!(:finish_issued, %{
        chain_pem: "fixture-chain",
        fingerprint: String.duplicate("a", 64),
        expires_at: DateTime.add(Ledger.now(), 30 * 24 * 3600)
      })
      |> Ledger.update!(:activate, %{})

    admin =
      Marshall.PasskeyFixture.user()
      |> Ledger.update!(:assign_administrator, %{administrator: true})
      |> Marshall.PasskeyFixture.verified_session()

    assert 0 = Marshall.Ingress.EnsureFleetCertificate.ensure_due!()

    assert {:ok, %{certificate_id: certificate_id, generation: 2}} =
             Ingress.rotate_fleet_certificate(%{}, actor: admin)

    assert [%{id: ^certificate_id, status: :pending}] =
             Ledger.read!(FleetCertificate, generation: 2)

    assert [%{id: current_id, status: :active}] =
             Ledger.read!(FleetCertificate, generation: 1)

    assert current_id == current.id

    assert [%{actor_id: actor_id, target_id: ^certificate_id, kind: :fleet_certificate_rotate}] =
             Ledger.read!(AdminEvent, target_id: certificate_id)

    assert actor_id == admin.id

    assert [%{actor_kind: :user, actor_id: ^actor_id}] =
             Ledger.read!(FleetCertificate.Version, version_source_id: certificate_id)

    assert {:error, _} = Ingress.rotate_fleet_certificate(%{}, actor: admin)
    assert 0 = Marshall.Ingress.EnsureFleetCertificate.ensure_due!()
    assert length(Ledger.read!(FleetCertificate, zone: zone)) == 2
    assert length(Ledger.read!(AdminEvent, target_id: certificate_id)) == 1
  end

  test "ordinary and stale forged administrators cannot request wildcard rotation" do
    ordinary = Marshall.PasskeyFixture.user()
    assert {:error, _} = Ingress.rotate_fleet_certificate(%{}, actor: ordinary)

    demoted =
      Marshall.PasskeyFixture.user()
      |> Ledger.update!(:assign_administrator, %{administrator: true})
      |> Marshall.PasskeyFixture.verified_session()
      |> Ledger.update!(:assign_administrator, %{administrator: false})

    assert {:error, _} =
             Ingress.rotate_fleet_certificate(%{}, actor: %{demoted | administrator: true})

    assert Ledger.read!(AdminEvent, kind: :fleet_certificate_rotate) == []
  end

  test "account, request key and chain are encrypted and absent from audit history" do
    account_key = :crypto.strong_rand_bytes(32)
    request_key = "request-key-" <> Base.encode64(:crypto.strong_rand_bytes(32))
    chain = "issued-chain-" <> Base.encode64(:crypto.strong_rand_bytes(32))
    csr = :crypto.strong_rand_bytes(64)

    account =
      Ledger.create!(FleetCertificateAccount, :register, %{
        issuer_url: "https://ca.example.test/directory",
        thumbprint: String.duplicate("a", 43),
        private_key: account_key
      })

    row =
      Ledger.create!(FleetCertificate, :enqueue, %{
        generation: 1,
        zone: "apps.example.test"
      })

    row =
      Ledger.update!(row, :save_request, %{
        csr_der: csr,
        private_key_pem: request_key,
        csr_fingerprint: Base.encode16(:crypto.hash(:sha256, csr), case: :lower)
      })

    row =
      Ledger.update!(row, :bind_order, %{
        order_url: "https://ca.example.test/order/1",
        finalize_url: "https://ca.example.test/finalize/1",
        authorization_url: "https://ca.example.test/auth/1"
      })

    row =
      Ledger.update!(row, :finish_issued, %{
        chain_pem: chain,
        fingerprint: String.duplicate("b", 64),
        expires_at: DateTime.add(Ledger.now(), 3600)
      })

    assert row.status == :issued
    assert %Ash.NotLoaded{} = row.private_key_pem
    assert %Ash.NotLoaded{} = row.chain_pem
    assert account.encrypted_private_key != account_key
    assert row.encrypted_private_key_pem != request_key
    assert row.encrypted_chain_pem != chain
    assert row.encrypted_csr_der != csr

    loaded_account = Ash.load!(account, :private_key, actor: SystemActor.compute())

    loaded_row =
      Ash.load!(row, [:csr_der, :private_key_pem, :chain_pem], actor: SystemActor.compute())

    assert loaded_account.private_key == account_key
    assert loaded_row.csr_der == csr
    assert loaded_row.private_key_pem == request_key
    assert loaded_row.chain_pem == chain

    versions =
      Ledger.read!(FleetCertificate.Version) ++ Ledger.read!(FleetCertificateAccount.Version)

    assert versions != []
    audit = inspect(versions)

    for secret <- [account_key, request_key, chain, csr] do
      refute :binary.match(audit, secret) != :nomatch
    end
  end

  test "only a current gateway receives the active encrypted bundle and may acknowledge it" do
    previous_zone = Application.get_env(:marshall, :ingress_zone)
    previous_acme = Application.get_env(:marshall, :fleet_acme)
    Application.put_env(:marshall, :ingress_zone, "apps.example.test")
    Application.put_env(:marshall, :fleet_acme, %{zone: "apps.example.test"})

    on_exit(fn ->
      if previous_zone,
        do: Application.put_env(:marshall, :ingress_zone, previous_zone),
        else: Application.delete_env(:marshall, :ingress_zone)

      restore_env(:fleet_acme, previous_acme)
    end)

    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {token, _} = Token.issue()

    {:ok, service} =
      Ingress.configure_service(
        %{
          name: "wildcard-" <> Ash.UUID.generate(),
          role: :gateway,
          host_id: fixture.vm.host_id,
          token: token,
          addresses: ["192.0.2.4"]
        },
        actor: SystemActor.compute()
      )

    chain = "secret-chain-" <> Base.encode64(:crypto.strong_rand_bytes(32))
    key = "secret-key-" <> Base.encode64(:crypto.strong_rand_bytes(32))
    fingerprint = String.duplicate("c", 64)
    expires = DateTime.add(Ledger.now(), 3600)

    certificate =
      Ledger.create!(FleetCertificate, :enqueue, %{generation: 5, zone: "apps.example.test"})
      |> Ledger.update!(:save_request, %{
        csr_der: :crypto.strong_rand_bytes(64),
        private_key_pem: key,
        csr_fingerprint: String.duplicate("e", 64)
      })
      |> Ledger.update!(:bind_order, %{
        order_url: "https://ca.example.test/order/5",
        finalize_url: "https://ca.example.test/finalize/5",
        authorization_url: "https://ca.example.test/auth/5"
      })
      |> Ledger.update!(:finish_issued, %{
        chain_pem: chain,
        fingerprint: fingerprint,
        expires_at: expires
      })
      |> Ledger.update!(:activate, %{})

    assert certificate.status == :active
    assert 0 = Marshall.Ingress.EnsureFleetCertificate.ensure_due!()

    assert {:ok, bundle} =
             Ingress.deliver_fleet_certificate(%{service_token: token},
               actor: SystemActor.compute()
             )

    assert bundle.host_id == fixture.vm.host_id
    assert bundle.generation == 5
    assert bundle.chain_pem == chain
    assert bundle.private_key_pem == key

    assert {:ok, %{generation: 5}} =
             Ingress.acknowledge_fleet_certificate(
               %{
                 service_token: token,
                 generation: 5,
                 fingerprint: fingerprint
               },
               actor: SystemActor.compute()
             )

    assert [%{service_id: id, fingerprint: ^fingerprint}] =
             Ledger.read!(FleetCertificateInstallation, host_id: fixture.vm.host_id)

    assert id == service.id

    assert {:ok, %{generation: 5}} =
             Ingress.acknowledge_fleet_certificate(
               %{service_token: token, generation: 5, fingerprint: fingerprint},
               actor: SystemActor.compute()
             )

    assert length(Ledger.read!(FleetCertificateInstallation, host_id: fixture.vm.host_id)) == 1
    versions_before_rotation = length(Ledger.read!(FleetCertificateInstallation.Version))

    {rotated_token, _} = Token.issue()

    {:ok, rotated_service} =
      Ingress.configure_service(
        %{
          name: to_string(service.name),
          role: :gateway,
          host_id: fixture.vm.host_id,
          token: rotated_token,
          addresses: ["192.0.2.4"]
        },
        actor: SystemActor.compute()
      )

    assert rotated_service.id == service.id
    assert rotated_service.generation == service.generation + 1

    assert {:error, _} =
             Ingress.acknowledge_fleet_certificate(
               %{service_token: token, generation: 5, fingerprint: fingerprint},
               actor: SystemActor.compute()
             )

    assert {:ok, %{generation: 5}} =
             Ingress.acknowledge_fleet_certificate(
               %{service_token: rotated_token, generation: 5, fingerprint: fingerprint},
               actor: SystemActor.compute()
             )

    assert [%{service_id: id, service_generation: generation, fingerprint: ^fingerprint}] =
             Ledger.read!(FleetCertificateInstallation, host_id: fixture.vm.host_id)

    assert id == rotated_service.id
    assert generation == rotated_service.generation

    assert length(Ledger.read!(FleetCertificateInstallation.Version)) ==
             versions_before_rotation + 1

    assert {:error, _} =
             Ingress.acknowledge_fleet_certificate(
               %{
                 service_token: rotated_token,
                 generation: 5,
                 fingerprint: String.duplicate("d", 64)
               },
               actor: SystemActor.compute()
             )
  end

  test "an uncertain ACME order is never repeated for its generation and recovers after quarantine" do
    zone = "apps.example.test"
    previous_zone = Application.get_env(:marshall, :ingress_zone)
    previous_acme = Application.get_env(:marshall, :fleet_acme)
    roots = Path.join(System.tmp_dir!(), "fleet-roots-#{System.unique_integer([:positive])}")
    File.write!(roots, "fixture-root")

    Application.put_env(:marshall, :ingress_zone, zone)

    Application.put_env(:marshall, :fleet_acme, %{
      zone: zone,
      directory: "https://acme.example.test/directory",
      issuer_ca_file: roots,
      roots_file: roots,
      nameservers: [{{192, 0, 2, 1}, 53}, {{192, 0, 2, 2}, 53}],
      accept_terms: true
    })

    on_exit(fn ->
      File.rm(roots)
      restore_env(:ingress_zone, previous_zone)
      restore_env(:fleet_acme, previous_acme)
    end)

    row = Ledger.create!(FleetCertificate, :enqueue, %{generation: 1, zone: zone})
    recent = DateTime.add(Ledger.now(), -3599, :second)
    Ledger.update!(row, :mark_order_attempt, %{order_attempted_at: recent})

    assert {:error, :unknown_order} = Marshall.Ingress.CertificateAuthority.step(row.id)
    assert [%{status: :pending}] = Ledger.read!(FleetCertificate, id: row.id)
    assert 0 = Marshall.Ingress.EnsureFleetCertificate.ensure_due!()

    old = DateTime.add(Ledger.now(), -3601, :second)

    Ledger.read!(FleetCertificate, id: row.id)
    |> hd()
    |> Ledger.update!(:mark_order_attempt, %{order_attempted_at: old})

    assert :ok = Marshall.Ingress.CertificateAuthority.step(row.id)
    assert [%{status: :failed}] = Ledger.read!(FleetCertificate, id: row.id)
    assert 1 = Marshall.Ingress.EnsureFleetCertificate.ensure_due!()
    assert [%{generation: 2, status: :pending}] = Ledger.read!(FleetCertificate, generation: 2)
  end

  test "a lost ACME newOrder response leaves one durable attempt and does not resend" do
    zone = "apps.example.test"
    previous_acme = Application.get_env(:marshall, :fleet_acme)
    counter = start_supervised!({Agent, fn -> 0 end})
    origin_ref = start_supervised!({Agent, fn -> "" end}, id: :origin_ref)
    owner = self()

    server =
      start_supervised!(
        {Bandit,
         [
           plug: {LostOrderReply, {origin_ref, counter, owner}},
           scheme: :https,
           ip: {127, 0, 0, 1},
           port: 0,
           certfile: @certificate,
           keyfile: @key,
           startup_log: false
         ]}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    origin = "https://127.0.0.1:#{port}"
    Agent.update(origin_ref, fn _ -> origin end)

    Application.put_env(:marshall, :fleet_acme, %{
      zone: zone,
      directory: origin <> "/dir",
      issuer_ca_file: @ca,
      roots_file: @ca,
      nameservers: [{{192, 0, 2, 1}, 53}, {{192, 0, 2, 2}, 53}],
      accept_terms: true
    })

    on_exit(fn -> restore_env(:fleet_acme, previous_acme) end)
    row = Ledger.create!(FleetCertificate, :enqueue, %{generation: 1, zone: zone})

    assert {:error, :unavailable} = Marshall.Ingress.CertificateAuthority.step(row.id)
    assert_receive :order_response_dropped

    assert [%{status: :pending, order_attempted_at: %DateTime{}}] =
             Ledger.read!(FleetCertificate, id: row.id)

    assert {:error, :unknown_order} = Marshall.Ingress.CertificateAuthority.step(row.id)
    assert Agent.get(counter, & &1) == 1
  end

  @spec restore_env(atom(), term()) :: :ok
  defp restore_env(key, nil), do: Application.delete_env(:marshall, key)
  defp restore_env(key, value), do: Application.put_env(:marshall, key, value)
end
