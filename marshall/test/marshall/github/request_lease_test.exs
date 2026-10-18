defmodule Marshall.GitHub.RequestLeaseTest do
  use Marshall.DataCase, async: false
  alias Marshall.Accounts.Security
  alias Marshall.Compute.Ledger
  alias Marshall.GitHub
  alias Marshall.GitHub.{Connection, Provider, RequestLease}
  @moduletag capture_log: true

  setup do
    settings = [
      github_provider: Marshall.GitHubTestProvider,
      github_client_id: "synthetic-client",
      github_client_secret_file: "/unused-test-path",
      github_redirect_uri: "https://example.test/auth/github-com/callback"
    ]

    originals = Map.new(settings, fn {key, _} -> {key, Application.fetch_env(:marshall, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:marshall, key, value) end)

    on_exit(fn ->
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:marshall, key, value)
        {key, :error} -> Application.delete_env(:marshall, key)
      end)
    end)

    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {actor, _} = Marshall.PasskeyFixture.login(fixture.owner)
    {:ok, fixture: fixture, actor: actor}
  end

  test "request pins match the VM owner and exclusions fence issuance and renewal", %{
    fixture: fixture,
    actor: actor
  } do
    assert {:ok, :anonymous} = GitHub.authorization(actor.id, fixture.vm.id)
    connection = connected!(actor.id)
    assert {:ok, pin} = GitHub.authorization(actor.id, fixture.vm.id)
    assert pin.token == "synthetic-access"
    assert pin.id == connection.id
    assert pin.ttl == 2000

    assert {:ok, %{ttl: _}} =
             GitHub.renew(actor.id, fixture.vm.id, pin.lease_id, pin.id, pin.generation)

    assert {:error, :unauthorized} =
             GitHub.renew(actor.id, fixture.vm.id, pin.lease_id, pin.id, pin.generation + 1)

    assert {:error, :unauthorized} =
             GitHub.authorization(Marshall.ComputeFixtures.user().id, fixture.vm.id)

    assert {:ok, _} = GitHub.set_excluded(actor, fixture.vm.id, true)
    assert {:ok, :anonymous} = GitHub.authorization(actor.id, fixture.vm.id)

    assert {:error, :unauthorized} =
             GitHub.renew(actor.id, fixture.vm.id, pin.lease_id, pin.id, pin.generation)

    assert {:ok, _} = GitHub.set_excluded(actor, fixture.vm.id, false)
    assert {:ok, _} = GitHub.authorization(actor.id, fixture.vm.id)
  end

  test "refresh drains the old durable request then rotates only after its close", %{
    fixture: fixture,
    actor: actor
  } do
    connection = connected!(actor.id)
    {:ok, pin} = GitHub.authorization(actor.id, fixture.vm.id)
    due_now!(connection.id)
    assert {:snooze, 2} = GitHub.refresh_connection(connection.id)
    assert {:error, :unavailable} = GitHub.authorization(actor.id, fixture.vm.id)

    assert {:ok, %{ttl: ttl} = renewal} =
             GitHub.renew(actor.id, fixture.vm.id, pin.lease_id, pin.id, pin.generation)

    assert ttl <= 2000
    assert Map.keys(renewal) == [:ttl]
    refute_receive {:refreshed, _}
    assert :ok = GitHub.close_lease(actor.id, fixture.vm.id, pin.lease_id)
    assert :ok = GitHub.refresh_connection(connection.id)
    assert_receive {:refreshed, "synthetic-refresh"}

    assert {:error, :unauthorized} =
             GitHub.renew(actor.id, fixture.vm.id, pin.lease_id, pin.id, pin.generation)

    assert {:ok, fresh_pin} = GitHub.authorization(actor.id, fixture.vm.id)
    assert fresh_pin.generation > pin.generation
  end

  test "removing OAuth configuration withdraws private admission and renewal", %{
    fixture: fixture,
    actor: actor
  } do
    connection = connected!(actor.id)
    assert {:ok, pin} = GitHub.authorization(actor.id, fixture.vm.id)

    for key <- [:github_client_id, :github_client_secret_file, :github_redirect_uri],
        do: Application.delete_env(:marshall, key)

    assert {:ok, :anonymous} = GitHub.authorization(actor.id, fixture.vm.id)
    assert {:ok, %{ttl: 2000}} = GitHub.renew_anonymous(actor.id, fixture.vm.id)

    assert {:error, :unauthorized} =
             GitHub.renew(actor.id, fixture.vm.id, pin.lease_id, pin.id, pin.generation)

    assert {:ok, %{configured: false}} = GitHub.status(actor)
    due_now!(connection.id)
    assert {:error, :unavailable} = GitHub.refresh_connection(connection.id)
    refute_receive {:refreshed, _}
    assert {:ok, %{phase: :connected}} = GitHub.status(actor)
  end

  test "expired pins and bounded drain deadlines refuse without sleeping", %{
    fixture: fixture,
    actor: actor
  } do
    connected!(actor.id)
    {:ok, pin} = GitHub.authorization(actor.id, fixture.vm.id)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE github_request_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE id=$1",
      [Ecto.UUID.dump!(pin.lease_id)],
      log: false
    )

    assert {:error, :unauthorized} =
             GitHub.renew(actor.id, fixture.vm.id, pin.lease_id, pin.id, pin.generation)

    [lease] = Ledger.read!(RequestLease)
    assert DateTime.diff(lease.maximum_expires_at, lease.inserted_at, :second) <= 300
  end

  test "disconnect immediately permits anonymous public traffic and fences the old generation", %{
    fixture: fixture,
    actor: actor
  } do
    connected!(actor.id)
    {:ok, pin} = GitHub.authorization(actor.id, fixture.vm.id)
    assert {:ok, %{phase: :revoking}} = GitHub.disconnect(actor)

    assert {:error, :unauthorized} =
             GitHub.renew(actor.id, fixture.vm.id, pin.lease_id, pin.id, pin.generation)

    assert {:ok, :anonymous} = GitHub.authorization(actor.id, fixture.vm.id)
    assert {:ok, %{ttl: 2000}} = GitHub.renew_anonymous(actor.id, fixture.vm.id)
    assert :ok = GitHub.revoke_connection(pin.id)
    assert_receive {:revoked, "synthetic-access"}
    assert {:ok, %{phase: :disconnected}} = GitHub.status(actor)
    refute Map.has_key?(actor.__metadata__, :github_access_token)
    assert is_binary(Security.jti(actor))
  end

  test "restored database credentials are fenced and erased before serving", %{
    fixture: fixture,
    actor: actor
  } do
    connected!(actor.id)
    {:ok, pin} = GitHub.authorization(actor.id, fixture.vm.id)
    assert :ok = GitHub.invalidate_restored_credentials!()
    assert {:ok, %{phase: :reconnect_required}} = GitHub.status(actor)
    [connection] = Ledger.read!(Connection)
    assert connection.generation > pin.generation
    assert connection.encrypted_credentials == nil
    assert [] = Ledger.read!(RequestLease)

    assert {:error, :unauthorized} =
             GitHub.renew(actor.id, fixture.vm.id, pin.lease_id, pin.id, pin.generation)

    assert {:ok, :anonymous} = GitHub.authorization(actor.id, fixture.vm.id)
    refute_receive {:revoked, _}
  end

  test "each durable restore epoch is applied once across repeat invocations", %{actor: actor} do
    connection = connected!(actor.id)
    epoch = Ash.UUID.generate()
    assert :ok = GitHub.apply_restore_epoch!(epoch)
    [once] = Ledger.read!(Connection)
    assert once.generation == connection.generation + 1
    assert :ok = GitHub.apply_restore_epoch!(epoch)
    [twice] = Ledger.read!(Connection)
    assert twice.generation == once.generation
    assert :ok = GitHub.apply_restore_epoch!(Ash.UUID.generate())
    [next] = Ledger.read!(Connection)
    assert next.generation == twice.generation + 1
  end

  test "cold restore hook ignores an absent marker and rejects malformed or indirect markers" do
    name = "MARSHALL_GITHUB_RESTORE_EPOCH_FILE"
    original = System.get_env(name)
    directory = Path.join(System.tmp_dir!(), "github-restore-#{Ash.UUID.generate()}")
    File.mkdir!(directory)

    on_exit(fn ->
      if original, do: System.put_env(name, original), else: System.delete_env(name)
      File.rm_rf!(directory)
    end)

    path = Path.join(directory, "epoch")
    System.put_env(name, path)
    assert :ok = GitHub.invalidate_restored_credentials_before_serving!()

    File.write!(path <> ".pending", "")

    assert_raise RuntimeError, "GitHub database restore is incomplete", fn ->
      GitHub.invalidate_restored_credentials_before_serving!()
    end

    File.rm!(path <> ".pending")

    File.write!(path, "invalid")

    assert_raise RuntimeError, "Invalid GitHub restore marker", fn ->
      GitHub.invalidate_restored_credentials_before_serving!()
    end

    File.write!(path, Ash.UUID.generate())
    indirect = Path.join(directory, "indirect")
    File.ln_s!(path, indirect)
    System.put_env(name, indirect)

    assert_raise RuntimeError, "Invalid GitHub restore marker", fn ->
      GitHub.invalidate_restored_credentials_before_serving!()
    end

    System.put_env(name, path)

    assert_raise RuntimeError,
                 "GitHub restore invalidation requires a stopped serving application",
                 fn ->
                   GitHub.invalidate_restored_credentials_before_serving!()
                 end
  end

  @spec connected!(binary()) :: Connection.t()
  defp connected!(user_id) do
    now = Ledger.now()
    connection = Ledger.create!(Connection, :register, %{user_id: user_id})

    Ledger.update!(connection, :connect, %{
      github_id: 42,
      github_login: "synthetic-user",
      generation: 2,
      scopes: Provider.scopes(),
      credentials: %{"access_token" => "synthetic-access", "refresh_token" => "synthetic-refresh"},
      expires_at: DateTime.add(now, 28_800, :second),
      refresh_expires_at: DateTime.add(now, 1_000_000, :second),
      refresh_due_at: DateTime.add(now, 28_200, :second)
    })
  end

  @spec due_now!(binary()) :: :ok
  defp due_now!(id) do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE github_connections SET refresh_due_at=clock_timestamp()-interval '1 second' WHERE id=$1",
      [Ecto.UUID.dump!(id)],
      log: false
    )

    :ok
  end
end
