defmodule Marshall.GitHub.AuthorizationTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Accounts.Security
  alias Marshall.Compute.Ledger
  alias Marshall.GitHub

  alias Marshall.GitHub.{
    AuthorizationAttempt,
    Connection,
    Grant,
    Persistence,
    Provider,
    RefreshAttempt
  }

  @moduletag capture_log: true

  setup do
    keys = [:github_client_id, :github_client_secret_file, :github_redirect_uri, :github_provider]
    originals = Map.new(keys, &{&1, Application.fetch_env(:marshall, &1)})
    Application.put_env(:marshall, :github_client_id, "synthetic-client")
    Application.put_env(:marshall, :github_client_secret_file, "/unused-test-path")

    Application.put_env(
      :marshall,
      :github_redirect_uri,
      "https://example.test/auth/github-com/callback"
    )

    Application.put_env(:marshall, :github_provider, Marshall.GitHubTestProvider)

    on_exit(fn ->
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:marshall, key, value)
        {key, :error} -> Application.delete_env(:marshall, key)
      end)
    end)

    :ok
  end

  test "one-use PKCE state binds the live login and never appears in status" do
    actor = actor()
    jti = Security.jti(actor)
    assert {:ok, ceremony} = GitHub.begin_authorization(actor, jti)
    query = URI.decode_query(URI.parse(ceremony.url).query)
    assert query["code_challenge_method"] == "S256"
    [attempt] = Ledger.read!(AuthorizationAttempt)
    assert match?(%Ash.NotLoaded{}, attempt.verifier)
    refute attempt.state_digest == query["state"]

    assert {:error, :invalid_callback} =
             GitHub.callback(actor, jti, String.duplicate("x", 43), "code")

    assert {:ok, %{phase: :connected, github_id: 42} = status} =
             GitHub.callback(actor, jti, query["state"], "code")

    assert_receive {:exchanged, "code", verifier}

    assert query["code_challenge"] ==
             :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    refute Map.has_key?(status, :credentials)
    assert {:error, :invalid_callback} = GitHub.callback(actor, jti, query["state"], "code")
    refute_receive {:exchanged, _, _}
    [connection] = Ledger.read!(Connection)
    assert match?(%Ash.NotLoaded{}, connection.credentials)

    %{rows: [[encrypted]]} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "SELECT encrypted_credentials FROM github_connections WHERE id=$1",
        [Ecto.UUID.dump!(connection.id)],
        log: false
      )

    refute :binary.match(encrypted, "synthetic-access") != :nomatch
  end

  test "expired, foreign-login and cancelled callback state cannot call the provider" do
    actor = actor()
    {:ok, ceremony} = GitHub.begin_authorization(actor, Security.jti(actor))
    query = URI.decode_query(URI.parse(ceremony.url).query)
    {other_session, _} = Marshall.PasskeyFixture.login(actor)

    assert {:error, :invalid_callback} =
             GitHub.callback(other_session, Security.jti(other_session), query["state"], "code")

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE github_authorization_attempts SET expires_at=clock_timestamp()-interval '1 second' WHERE id=$1",
      [Ecto.UUID.dump!(ceremony.attempt_id)],
      log: false
    )

    assert {:error, :invalid_callback} =
             GitHub.callback(actor, Security.jti(actor), query["state"], "code")

    assert {:ok, %{phase: :revoking}} = GitHub.disconnect(actor)

    assert {:error, :invalid_callback} =
             GitHub.callback(actor, Security.jti(actor), query["state"], "code")

    refute_receive {:exchanged, _, _}
  end

  test "the same numeric GitHub account cannot be connected to two users" do
    first = actor()
    second = actor()
    assert {:ok, %{phase: :connected}} = connect(first)
    assert {:error, :identity_in_use} = connect(second)
    assert Enum.count(Ledger.read!(Connection), &(&1.phase == :connected)) == 1
  end

  test "a ceremony cannot exchange after its stored login is revoked" do
    actor = actor()
    {:ok, ceremony} = GitHub.begin_authorization(actor, Security.jti(actor))
    state = URI.decode_query(URI.parse(ceremony.url).query)["state"]
    Marshall.Accounts.AccountLifecycle.revoke_tokens!(actor.id)
    assert {:error, :unauthorized} = GitHub.callback(actor, Security.jti(actor), state, "code")
    refute_receive {:exchanged, _, _}
    [connection] = Ledger.read!(Connection)
    assert connection.phase == :disconnected
  end

  test "ambiguous refresh fails closed and a duplicate job cannot resend the rotating token" do
    actor = actor()
    assert {:ok, _} = connect(actor)
    [connection] = Ledger.read!(Connection)
    due_now!(connection.id)
    Process.put(:github_refresh_mode, :ambiguous)
    assert :ok = GitHub.refresh_connection(connection.id)
    assert_receive {:refreshed, "synthetic-refresh"}
    assert {:ok, %{phase: :reconnect_required}} = GitHub.status(actor)
    assert :ok = GitHub.refresh_connection(connection.id)
    refute_receive {:refreshed, _}
    [attempt] = Ledger.read!(RefreshAttempt)
    assert attempt.phase == :failed
  end

  test "a submitted attempt left by a worker death cannot be replayed" do
    actor = actor()
    assert {:ok, _} = connect(actor)
    [connection] = Ledger.read!(Connection)

    attempt =
      Ledger.create!(RefreshAttempt, :record, %{
        connection_id: connection.id,
        generation: connection.generation
      })

    connection =
      Ledger.update!(connection, :drain, %{
        refresh_attempt_id: attempt.id,
        drain_deadline: Ledger.now()
      })

    Ledger.update!(connection, :start_refresh, %{generation: connection.generation + 1})

    Ledger.update!(attempt, :submit, %{
      submission_expires_at: DateTime.add(Ledger.now(), -1, :second)
    })

    assert :ok = GitHub.refresh_connection(connection.id)
    assert {:ok, %{phase: :reconnect_required}} = GitHub.status(actor)
    refute_receive {:refreshed, _}
  end

  test "a callback result arriving after disconnect cannot resurrect its identity" do
    actor = actor()
    {:ok, ceremony} = GitHub.begin_authorization(actor, Security.jti(actor))
    state = URI.decode_query(URI.parse(ceremony.url).query)["state"]
    parent = self()
    ref = make_ref()

    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Process.put(:github_test_gate, {parent, ref})
        GitHub.callback(actor, Security.jti(actor), state, "code")
      end)

    assert_receive {:github_exchange_started, caller, ^ref}
    assert {:ok, %{phase: :revoking}} = GitHub.disconnect(actor)
    send(caller, {:release, ref})
    assert {:error, :invalid_callback} = Task.await(task)
    [connection] = Ledger.read!(Connection)
    assert connection.phase == :revoking
    assert connection.github_id == nil
    assert :ok = GitHub.cleanup_authorization(ceremony.attempt_id)
    assert_receive {:revoked_token, "synthetic-access"}
  end

  test "refresh identity drift requires reconnect instead of changing the owner identity" do
    actor = actor()
    assert {:ok, _} = connect(actor)
    [connection] = Ledger.read!(Connection)
    due_now!(connection.id)
    Process.put(:github_identity, 43)
    assert :ok = GitHub.refresh_connection(connection.id)
    assert {:ok, %{phase: :reconnect_required, github_id: 42}} = GitHub.status(actor)
    [attempt] = Ledger.read!(RefreshAttempt)
    assert attempt.encrypted_result != nil
    assert :ok = GitHub.cleanup_refresh(attempt.id)
    assert_receive {:revoked_token, "synthetic-access"}
    [cleaned] = Ledger.read!(RefreshAttempt)
    assert cleaned.encrypted_result == nil
  end

  test "a refresh result received after disconnect is retained for token-scoped cleanup" do
    actor = actor()
    assert {:ok, _} = connect(actor)
    [connection] = Ledger.read!(Connection)
    due_now!(connection.id)
    parent = self()
    ref = make_ref()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Process.put(:github_test_gate, {parent, ref})
        GitHub.refresh_connection(connection.id)
      end)

    assert_receive {:github_exchange_started, caller, ^ref}
    assert {:ok, %{phase: :revoking}} = GitHub.disconnect(actor)
    send(caller, {:release, ref})
    assert :ok = Task.await(task)
    assert {:ok, %{phase: :revoking}} = GitHub.status(actor)
    [attempt] = Ledger.read!(RefreshAttempt)
    assert attempt.phase == :failed
    assert attempt.encrypted_result != nil
    assert :ok = GitHub.cleanup_refresh(attempt.id)
    assert_receive {:revoked_token, "synthetic-access"}
  end

  test "a lost commit acknowledgement retries the same staged pair without another exchange" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Marshall.Repo, fn ->
      before = Marshall.CommittedFixtureInventory.snapshot()
      actor = actor()

      Marshall.CommittedFixtureCleanup.run(
        fn ->
          assert {:ok, _} = connect(actor)
          [connection] = Ledger.read!(Connection)

          attempt =
            Ledger.create!(RefreshAttempt, :record, %{
              connection_id: connection.id,
              generation: connection.generation
            })

          attempt = Ledger.update!(attempt, :submit, %{})

          pair =
            Grant.encode(%Grant{
              access_token: "new-synthetic-access",
              refresh_token: "new-synthetic-refresh",
              expires_in: 28_800,
              refresh_expires_in: 1_000_000,
              scopes: Provider.scopes()
            })

          Process.put(:github_stage_count, 0)

          assert {:ok, staged} =
                   Persistence.transaction(fn ->
                     count = Process.get(:github_stage_count)
                     Process.put(:github_stage_count, count + 1)
                     current = Ledger.lock!(RefreshAttempt, attempt.id)

                     case current.phase do
                       :submitted ->
                         staged = Ledger.update!(current, :stage, %{result: pair})

                         Ledger.after_commit(fn ->
                           raise "synthetic lost commit acknowledgement"
                         end)

                         staged

                       :staged ->
                         assert Ash.load!(current, :result,
                                  actor: Marshall.Authorization.SystemActor.compute()
                                ).result == pair

                         current
                     end
                   end)

          assert staged.phase == :staged
          assert Process.get(:github_stage_count) == 2
          refute_receive {:refreshed, _}
        end,
        fn -> Marshall.GitHubDistributedFixture.cleanup!(actor) end
      )

      Marshall.CommittedFixtureInventory.assert_restored!(before)
    end)
  end

  @tag :hegel_case_sandbox
  property "callback histories retain one-use state across arbitrary replays and disconnects",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()

    commands =
      draw(
        "commands",
        list_of(member_of([:callback, :replay, :disconnect]), min_length: 1, max_length: 16)
      )

    actor = actor()
    {:ok, ceremony} = GitHub.begin_authorization(actor, Security.jti(actor))
    state = URI.decode_query(URI.parse(ceremony.url).query)["state"]

    Enum.reduce(commands, :pending, fn command, model ->
      case command do
        :disconnect ->
          assert {:ok, %{phase: :revoking}} = GitHub.disconnect(actor)
          :disconnected

        _ ->
          result = GitHub.callback(actor, Security.jti(actor), state, "code")

          if model == :pending do
            assert {:ok, %{phase: :connected}} = result
            :consumed
          else
            assert {:error, :invalid_callback} = result
            model
          end
      end
    end)

    assert Enum.count(Ledger.read!(AuthorizationAttempt), &(&1.phase == :consumed)) <= 1
  end

  @spec actor() :: Marshall.Accounts.User.t()
  defp actor do
    {actor, _} = Marshall.PasskeyFixture.user() |> Marshall.PasskeyFixture.login()
    actor
  end

  @spec connect(Marshall.Accounts.User.t()) ::
          {:ok, GitHub.status_info()} | {:error, GitHub.error()}
  defp connect(actor) do
    {:ok, ceremony} = GitHub.begin_authorization(actor, Security.jti(actor))
    state = URI.decode_query(URI.parse(ceremony.url).query)["state"]
    GitHub.callback(actor, Security.jti(actor), state, "code")
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
