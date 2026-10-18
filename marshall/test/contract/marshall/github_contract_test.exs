defmodule MarshallGitHubContractTest do
  use Covenant.Case, component: "marshall.github", async: false
  alias Marshall.Accounts.Security
  alias Marshall.Compute.Ledger
  alias Marshall.GitHub
  alias Marshall.GitHub.{AuthorizationAttempt, Connection, RequestLease}
  @moduletag capture_log: true

  setup tags do
    :ok = Marshall.DataCase.setup_sandbox(tags)

    settings = [
      github_client_id: "synthetic-client",
      github_client_secret_file: "/unused-test-path",
      github_redirect_uri: "https://example.test/auth/github-com/callback",
      github_provider: Marshall.GitHubTestProvider
    ]

    originals = Map.new(settings, fn {key, _} -> {key, Application.fetch_env(:marshall, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:marshall, key, value) end)

    on_exit(fn ->
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:marshall, key, value)
        {key, :error} -> Application.delete_env(:marshall, key)
      end)
    end)

    :ok
  end

  @tag obligation: "marshall.github.I1"
  test "another live login cannot consume a ceremony and replay cannot exchange again" do
    {actor, _} = Marshall.PasskeyFixture.user() |> Marshall.PasskeyFixture.login()
    {other_login, _} = Marshall.PasskeyFixture.login(actor)
    {:ok, ceremony} = GitHub.begin_authorization(actor, Security.jti(actor))
    state = URI.decode_query(URI.parse(ceremony.url).query)["state"]

    assert {:error, :invalid_callback} =
             GitHub.callback(other_login, Security.jti(other_login), state, "code")

    assert {:ok, %{phase: :connected}} =
             GitHub.callback(actor, Security.jti(actor), state, "code")

    assert_receive {:exchanged, "code", _}

    assert {:error, :invalid_callback} =
             GitHub.callback(actor, Security.jti(actor), state, "code")

    refute_receive {:exchanged, _, _}
    assert {:ok, status} = GitHub.status(actor)

    assert Map.keys(status) |> Enum.sort() == [
             :configured,
             :exclusions,
             :expires_at,
             :github_id,
             :github_login,
             :phase,
             :scopes
           ]

    [attempt] = Ledger.read!(AuthorizationAttempt)
    assert attempt.encrypted_verifier == nil
    assert attempt.encrypted_issued_credentials == nil
  end

  @tag obligation: "marshall.github.I2"
  test "disconnect refuses old pins and returns credential-free anonymous admission" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {actor, _} = Marshall.PasskeyFixture.login(fixture.owner)
    assert {:ok, _} = connect(actor)
    assert {:ok, pin} = GitHub.authorization(actor.id, fixture.vm.id)
    assert {:ok, %{phase: :revoking}} = GitHub.disconnect(actor)

    assert {:error, :unauthorized} =
             GitHub.renew(actor.id, fixture.vm.id, pin.lease_id, pin.id, pin.generation)

    assert {:ok, :anonymous} = GitHub.authorization(actor.id, fixture.vm.id)
  end

  @tag obligation: "marshall.github.I3"
  test "a restore epoch removes credentials and ceremonies and is idempotent" do
    {actor, _} = Marshall.PasskeyFixture.user() |> Marshall.PasskeyFixture.login()
    assert {:ok, _} = connect(actor)
    [before] = Ledger.read!(Connection)
    epoch = Ash.UUID.generate()
    assert :ok = GitHub.apply_restore_epoch!(epoch)
    [after_restore] = Ledger.read!(Connection)
    assert after_restore.phase == :reconnect_required
    assert after_restore.encrypted_credentials == nil
    assert after_restore.generation > before.generation
    assert [] = Ledger.read!(AuthorizationAttempt)
    assert [] = Ledger.read!(RequestLease)
    assert :ok = GitHub.apply_restore_epoch!(epoch)
    [repeated] = Ledger.read!(Connection)
    assert repeated.generation == after_restore.generation
  end

  @spec connect(Marshall.Accounts.User.t()) ::
          {:ok, GitHub.status_info()} | {:error, GitHub.error()}
  defp connect(actor) do
    {:ok, ceremony} = GitHub.begin_authorization(actor, Security.jti(actor))
    state = URI.decode_query(URI.parse(ceremony.url).query)["state"]
    GitHub.callback(actor, Security.jti(actor), state, "code")
  end
end
