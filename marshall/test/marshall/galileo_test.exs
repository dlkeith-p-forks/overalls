defmodule Marshall.GalileoTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import ExUnit.CaptureLog
  alias Marshall.Compute.Ledger
  alias Marshall.Accounts.AdminEvent
  alias Marshall.Galileo
  alias Marshall.Galileo.{Attachment, Credentials, Integration, IntegrationHeader, PeerTokens}

  property "exclusive integration cursors enumerate every visible row exactly once",
    test_cases: 15 do
    check all(count <- integer(1..6), limit <- integer(1..3), test_cases: 15) do
      actor = Marshall.ComputeFixtures.user()

      integrations =
        for _ <- 1..count do
          {:ok, integration} = configure(actor, %{name: "page" <> Ash.UUID.generate()})
          integration
        end

      {:ok, expected} = Galileo.list_integrations(%{limit: 100}, actor: actor)

      {seen, cursor} =
        Enum.reduce(1..count, {[], nil}, fn _, {seen, cursor} ->
          {:ok, page} = Galileo.list_integrations(%{after: cursor, limit: limit}, actor: actor)
          next = if page == [], do: cursor, else: List.last(page).id
          {seen ++ Enum.map(page, & &1.id), next}
        end)

      assert seen == Enum.map(expected, & &1.id)
      assert length(Enum.uniq(seen)) == count
      assert Enum.sort(seen) == Enum.sort(Enum.map(integrations, & &1.id))
      assert {:ok, []} = Galileo.list_integrations(%{after: cursor, limit: limit}, actor: actor)

      assert {:ok, []} =
               Galileo.list_integrations(%{after: Ash.UUID.generate(), limit: limit},
                 actor: actor
               )
    end
  end

  defp configure(actor, overrides \\ %{}) do
    Galileo.configure_integration(
      Map.merge(
        %{
          name: "exedev",
          target: "https://api.example.test",
          strip_prefix: nil,
          headers: [%{kind: :bearer, name: "authorization", value: "sk-secret-1"}],
          peer: false,
          peer_vm_id: nil,
          team_id: nil,
          idempotency_key: Ash.UUID.generate()
        },
        overrides
      ),
      actor: actor
    )
  end

  test "configure persists an integration and encrypts secret values at rest" do
    actor = Marshall.ComputeFixtures.user()
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    configured_logs =
      capture_log([metadata: [:event, :operation_status]], fn ->
        {:ok, integration} = configure(actor)

        assert integration.name == "exedev"
        assert integration.owner_id == actor.id
      end)

    assert configured_logs =~ "event=galileo.integration_configured"
    assert configured_logs =~ "operation_status=configured"

    assert [%{kind: :galileo_configure, actor_id: actor_id}] = Ledger.read!(AdminEvent)
    assert actor_id == actor.id

    {:ok, integration} = configure(actor)

    [header] = Ledger.read!(IntegrationHeader, integration_id: integration.id)
    assert header.kind == :bearer
    assert header.encrypted_value != "sk-secret-1"

    [decrypted] = Ash.load!([header], :value)
    assert decrypted.value == "sk-secret-1"
  end

  test "configure is idempotent per key and conflicts on changed payload" do
    actor = Marshall.ComputeFixtures.user()
    key = Ash.UUID.generate()

    assert {:ok, first} =
             configure(actor, %{
               idempotency_key: key,
               headers: [%{kind: :bearer, name: "authorization", value: "sk-a"}]
             })

    assert {:ok, replay} =
             configure(actor, %{
               idempotency_key: key,
               headers: [%{kind: :bearer, name: "authorization", value: "sk-a"}]
             })

    assert replay.id == first.id

    assert {:error, conflict} =
             configure(actor, %{
               idempotency_key: key,
               headers: [%{kind: :bearer, name: "authorization", value: "sk-b"}]
             })

    assert Exception.message(conflict) =~ "idempotency_conflict"

    assert {:ok, updated} =
             configure(actor, %{
               idempotency_key: Ash.UUID.generate(),
               headers: [%{kind: :bearer, name: "authorization", value: "sk-b"}]
             })

    assert updated.id == first.id
    [header] = Ledger.read!(IntegrationHeader, integration_id: updated.id)
    [decrypted] = Ash.load!([header], :value)
    assert decrypted.value == "sk-b"
  end

  test "create or replace atomically changes peer mode and ownership" do
    actor = Marshall.ComputeFixtures.user()
    peer = Marshall.TerminalFixtures.terminal_fixture().vm
    {:ok, first} = configure(actor)

    {:ok, team} =
      Marshall.Teams.create_team(
        %{name: "integration-team", idempotency_key: Ash.UUID.generate()},
        actor: actor
      )

    assert {:ok, replaced} =
             configure(actor, %{
               target: nil,
               peer: true,
               peer_vm_id: peer.id,
               team_id: team.id,
               headers: [],
               idempotency_key: Ash.UUID.generate()
             })

    assert replaced.id == first.id
    assert replaced.peer
    assert replaced.peer_vm_id == peer.id
    assert replaced.owner_id == nil
    assert replaced.team_id == team.id
    assert replaced.target == nil
    assert Ledger.read!(IntegrationHeader, integration_id: replaced.id) == []

    assert {:ok, direct} =
             configure(actor, %{
               target: "https://replacement.example.test",
               peer: false,
               peer_vm_id: nil,
               team_id: nil,
               idempotency_key: Ash.UUID.generate()
             })

    assert direct.id == first.id
    refute direct.peer
    assert direct.peer_vm_id == nil
    assert direct.owner_id == actor.id
    assert direct.team_id == nil
    assert direct.target == "https://replacement.example.test"
  end

  # @cc [owner:ghuntley,label:verification;product] galileo-removed-name-closed-refusal
  # A removed integration's name is permanently closed: identical replay, changed
  # payloads and re-keyed retries of configure MUST fail with the name_unavailable
  # refusal — never an archived-row success, :configured receipt or an unmapped
  # stale-record exception — and MUST leave history, receipts and headers intact.
  test "removed names refuse configuration without receipts or stale exceptions" do
    actor = Marshall.ComputeFixtures.user()
    key = Ash.UUID.generate()

    assert {:ok, integration} =
             configure(actor, %{
               idempotency_key: key,
               headers: [%{kind: :bearer, name: "authorization", value: "sk-a"}]
             })

    assert {:ok, _} = Galileo.remove_integration(%{name: "exedev"}, actor: actor)
    assert [%{archived_at: %DateTime{}}] = Ledger.history!(Integration, id: integration.id)

    identical = %{
      idempotency_key: key,
      headers: [%{kind: :bearer, name: "authorization", value: "sk-a"}]
    }

    assert {:error, identical_error} = configure(actor, identical)
    assert Exception.message(identical_error) =~ "name_unavailable"

    assert {:error, changed_error} =
             configure(actor, %{
               idempotency_key: Ash.UUID.generate(),
               target: "https://changed.example.test",
               headers: [%{kind: :bearer, name: "authorization", value: "sk-b"}]
             })

    assert Exception.message(changed_error) =~ "name_unavailable"

    assert {:error, rekeyed_error} =
             configure(actor, %{
               idempotency_key: key,
               headers: [%{kind: :bearer, name: "authorization", value: "sk-c"}]
             })

    assert Exception.message(rekeyed_error) =~ "name_unavailable"

    assert [%{archived_at: %DateTime{}}] = Ledger.history!(Integration, id: integration.id)

    assert [%{kind: :galileo_configure}, %{kind: :galileo_remove}] =
             Ledger.read!(AdminEvent, target_id: integration.id)
             |> Enum.sort_by(&DateTime.to_unix(&1.inserted_at, :microsecond))

    assert [%{value: "sk-a"}] =
             IntegrationHeader
             |> Ledger.read!(integration_id: integration.id)
             |> Ash.load!(:value, actor: Marshall.Authorization.SystemActor.compute())
             |> Enum.map(&Map.take(&1, [:value]))
  end

  test "a foreign actor cannot distinguish a removed name from manage authority" do
    actor = Marshall.ComputeFixtures.user()
    stranger = Marshall.ComputeFixtures.user()
    {:ok, _integration} = configure(actor)
    assert {:ok, _} = Galileo.remove_integration(%{name: "exedev"}, actor: actor)

    assert {:error, error} = configure(stranger, %{idempotency_key: Ash.UUID.generate()})
    assert Exception.message(error) =~ "forbidden"
  end

  test "persistence rejects malformed bearer and basic credentials" do
    actor = Marshall.ComputeFixtures.user()

    for header <- [
          %{kind: :bearer, name: "authorization", value: "bad\nvalue"},
          %{kind: :basic, name: "authorization", value: "missing-colon"},
          %{kind: :basic, name: "authorization", value: ":password"},
          %{kind: :bearer, name: "authorization", value: "-"}
        ] do
      assert {:error, _} =
               configure(actor, %{
                 name: "invalid-#{System.unique_integer([:positive])}",
                 headers: [header]
               })
    end
  end

  property "malformed routing and static headers refuse without exceptions or persistence",
    test_cases: 15 do
    actor = Marshall.ComputeFixtures.user()

    check all(
            kind <- member_of([:target, :prefix, :header]),
            suffix <- string(:alphanumeric, min_length: 1, max_length: 12),
            test_cases: 15
          ) do
      {overrides, reason} =
        case kind do
          :target ->
            {%{target: "http://#{suffix}.example.test"}, "invalid_target"}

          :prefix ->
            {%{strip_prefix: "/#{suffix}//bad"}, "invalid_strip_prefix"}

          :header ->
            {%{
               headers: [%{kind: :static, name: "authorization", value: "private-invalid-secret"}]
             }, "invalid_header"}
        end

      assert {:error, error} = configure(actor, overrides)
      assert Exception.message(error) =~ reason
      refute Exception.message(error) =~ "private-invalid-secret"
      assert Ledger.read!(Integration) == []
      assert Ledger.read!(IntegrationHeader) == []
      assert Ledger.read!(AdminEvent) == []
    end
  end

  test "only managers configure and views never return stored values" do
    actor = Marshall.ComputeFixtures.user()
    other = Marshall.ComputeFixtures.user()
    {:ok, integration} = configure(actor)

    assert {:error, error} =
             configure(other, %{name: "exedev", idempotency_key: Ash.UUID.generate()})

    assert Exception.message(error) =~ "forbidden"

    assert {:ok, view} = Galileo.show_integration(%{name: "exedev"}, actor: actor)
    assert [%{kind: :bearer, name: "authorization"}] = view.headers
    assert view.headers == [%{kind: :bearer, name: "authorization"}]

    assert {:error, _} = Galileo.show_integration(%{name: "missing"}, actor: actor)
    assert integration.id
  end

  test "attachment is explicit, idempotent and detaches cleanly" do
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    actor = Marshall.ComputeFixtures.user()
    other = Marshall.ComputeFixtures.user()
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {:ok, integration} = configure(actor)

    assert {:error, _} =
             Galileo.attach_integration(%{name: "exedev", vm_id: fixture.vm.id}, actor: other)

    attach_logs =
      capture_log([metadata: [:event, :operation_status, :vm_id]], fn ->
        assert {:ok, %{attached: "exedev", integration_id: integration_id}} =
                 Galileo.attach_integration(%{name: "exedev", vm_id: fixture.vm.id}, actor: actor)

        assert integration_id == integration.id

        assert {:ok, %{attached: "exedev"}} =
                 Galileo.attach_integration(%{name: "exedev", vm_id: fixture.vm.id}, actor: actor)
      end)

    assert attach_logs =~ "event=galileo.integration_configured"
    assert attach_logs =~ "operation_status=attached"
    assert attach_logs =~ fixture.vm.id

    assert [attachment] =
             Ledger.read!(Attachment, integration_id: integration.id, vm_id: fixture.vm.id)

    assert {:ok, %{detached: "exedev"}} =
             Galileo.detach_integration(%{name: "exedev", vm_id: fixture.vm.id}, actor: actor)

    assert [] == Ledger.read!(Attachment, integration_id: integration.id, vm_id: fixture.vm.id)
    assert attachment.id

    detach_logs =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :operation_status]], fn ->
        assert {:ok, %{detached: "exedev"}} =
                 Galileo.detach_integration(%{name: "exedev", vm_id: fixture.vm.id}, actor: actor)
      end)

    assert detach_logs =~ "event=galileo.integration_configured"
    assert detach_logs =~ "operation_status=detached"
  end

  test "credential rotation revokes prior secrets and authenticates current" do
    fixture = Marshall.ComputeFixtures.host_fixture()
    {:ok, first} = Credentials.rotate(fixture.host.id, 3600)
    {:ok, second} = Credentials.rotate(fixture.host.id, 3600)
    assert first.id != second.id

    assert {:error, _} = Credentials.authenticate(first.id <> "." <> first.secret)

    expected_host = fixture.host.id

    assert {:ok, %{host_id: ^expected_host}} =
             Credentials.authenticate(second.id <> "." <> second.secret)

    assert {:ok, :ok} = Credentials.revoke(fixture.host.id)
    assert {:error, _} = Credentials.authenticate(second.id <> "." <> second.secret)
  end

  test "peer tokens persist only digests and atomically admit one verifier" do
    actor = Marshall.ComputeFixtures.user()
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {:ok, integration} = configure(actor)
    token = PeerTokens.mint(fixture.vm.id, integration.id, integration.name)

    assert byte_size(token) == 56

    %{rows: [[digest, source_vm_id, integration_id]]} =
      Marshall.Repo.query!(
        "SELECT digest, source_vm_id::text, integration_id::text FROM galileo_peer_tokens",
        [],
        log: false
      )

    assert digest == :crypto.hash(:sha256, token)
    assert source_vm_id == fixture.vm.id
    assert integration_id == integration.id

    results =
      1..8
      |> Task.async_stream(fn _ -> PeerTokens.verify(token) end,
        max_concurrency: 8,
        ordered: false,
        timeout: 5000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_peer_token})) == 7
    assert {:error, :invalid_peer_token} = PeerTokens.verify(token)
  end

  test "peer tokens cannot outlive their integration" do
    actor = Marshall.ComputeFixtures.user()
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {:ok, integration} = configure(actor)
    token = PeerTokens.mint(fixture.vm.id, integration.id, integration.name)
    assert {:ok, _} = Galileo.remove_integration(%{name: integration.name}, actor: actor)
    assert {:error, :invalid_peer_token} = PeerTokens.verify(token)
  end

  test "peer token expiry uses the database deadline and failure is uniform" do
    actor = Marshall.ComputeFixtures.user()
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {:ok, integration} = configure(actor)
    token = PeerTokens.mint(fixture.vm.id, integration.id, integration.name)

    Marshall.Repo.query!(
      "UPDATE galileo_peer_tokens SET expires_at = clock_timestamp() - interval '1 second'",
      [],
      log: false
    )

    for invalid <- [token, "galileo_peer_bogus", String.duplicate("x", 56), nil] do
      assert {:error, :invalid_peer_token} = PeerTokens.verify(invalid)
    end

    fresh = PeerTokens.mint(fixture.vm.id, integration.id, integration.name)

    %{rows: [[1]]} =
      Marshall.Repo.query!(
        "SELECT count(*) FROM galileo_peer_tokens WHERE expires_at > clock_timestamp()",
        [],
        log: false
      )

    %{rows: [[0]]} =
      Marshall.Repo.query!(
        "SELECT count(*) FROM galileo_peer_tokens WHERE expires_at <= clock_timestamp()",
        [],
        log: false
      )

    assert {:ok, _} = PeerTokens.verify(fresh)
  end
end
