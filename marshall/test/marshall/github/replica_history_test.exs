defmodule Marshall.GitHub.ReplicaHistoryTest do
  use ExUnit.Case, async: false
  alias Marshall.Accounts.Security
  alias Marshall.CommittedFixtureCleanup, as: Cleanup
  alias Marshall.GitHub
  alias Marshall.GitHubDistributedFixture, as: Fixture
  alias Marshall.Repo
  require Cleanup
  @moduletag :distributed
  @moduletag timeout: 120_000
  @moduletag capture_log: true

  setup_all do
    peers =
      Enum.map([:github_authority_1, :github_authority_2, :github_authority_3], &boot_peer!/1)

    nodes = Enum.map(peers, &:peer.call(&1, :erlang, :node, []))
    assert length(Enum.uniq(nodes)) == 3
    refute node() in nodes

    unless Node.alive?() do
      {:ok, _} = Node.start(String.to_atom("github_observer_#{System.pid()}"), :shortnames)
      on_exit(fn -> Node.stop() end)
    end

    Enum.each(peers, &connect_observer!/1)
    %{peers: peers}
  end

  setup do
    before =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &Marshall.CommittedFixtureInventory.snapshot/0)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Marshall.CommittedFixtureInventory.assert_restored!(before)
      end)
    end)

    :ok
  end

  test "disconnect committed on another replica defeats a delayed callback result", %{
    peers: [worker, authority, observer] = peers
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      {actor, _} = Marshall.PasskeyFixture.user() |> Marshall.PasskeyFixture.login()

      Cleanup.protect peers do
        {:ok, ceremony} =
          :peer.call(authority, GitHub, :begin_authorization, [actor, Security.jti(actor)])

        state = URI.decode_query(URI.parse(ceremony.url).query)["state"]
        owner = self()
        reference = make_ref()

        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            :peer.call(
              worker,
              Fixture,
              :callback,
              [actor, Security.jti(actor), state, owner, reference],
              35_000
            )
          end)

        assert_receive {:github_exchange_started, responder, ^reference}, 10_000

        try do
          assert {:ok, %{phase: :revoking}} = :peer.call(authority, GitHub, :disconnect, [actor])
          assert {:ok, %{phase: :revoking}} = :peer.call(observer, GitHub, :status, [actor])
        after
          send(responder, {:release, reference})
        end

        assert {:error, :invalid_callback} = Task.await(task, 35_000)

        assert %{connections: [%{phase: :revoking, github_id: nil}]} =
                 :peer.call(observer, Fixture, :snapshot, [actor.id])

        assert :ok = :peer.call(observer, GitHub, :cleanup_authorization, [ceremony.attempt_id])
      after
        Fixture.cleanup!(actor)
      end
    end)
  end

  test "duplicate refresh workers on separate replicas never exchange the same pair twice", %{
    peers: [worker, authority, observer] = peers
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      {actor, _} = Marshall.PasskeyFixture.user() |> Marshall.PasskeyFixture.login()

      Cleanup.protect peers do
        assert {:ok, _} = :peer.call(authority, Fixture, :connect, [actor])
        %{connections: [connection]} = :peer.call(observer, Fixture, :snapshot, [actor.id])
        :ok = Fixture.due!(connection.id)
        owner = self()
        reference = make_ref()

        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            :peer.call(worker, Fixture, :refresh, [connection.id, owner, reference], 35_000)
          end)

        assert_receive {:github_exchange_started, responder, ^reference}, 10_000

        try do
          assert {:snooze, 2} =
                   :peer.call(authority, GitHub, :refresh_connection, [connection.id])

          assert %{connections: [%{phase: :refreshing}], attempts: [%{phase: :submitted}]} =
                   :peer.call(observer, Fixture, :snapshot, [actor.id])
        after
          send(responder, {:release, reference})
        end

        assert :ok = Task.await(task, 35_000)

        assert %{
                 connections: [%{phase: :connected, generation: generation}],
                 attempts: [%{phase: :finished}]
               } =
                 :peer.call(observer, Fixture, :snapshot, [actor.id])

        assert generation == connection.generation + 1
      after
        Fixture.cleanup!(actor)
      end
    end)
  end

  @spec boot_peer!(atom()) :: pid()
  defp boot_peer!(name) do
    peer =
      start_supervised!(%{
        id: name,
        start:
          {:peer, :start_link,
           [
             %{
               name: String.to_atom("#{name}_#{System.pid()}"),
               connection: :standard_io,
               args: [~c"+S", ~c"2:2", ~c"+SDcpu", ~c"1", ~c"+SDio", ~c"1"],
               wait_boot: 30_000
             }
           ]},
        restart: :temporary
      })

    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])

    config =
      for {app, _, _} <- Application.loaded_applications(),
          app not in [:kernel, :stdlib, :elixir, :logger],
          do: {app, Application.get_all_env(app)}

    :ok = :peer.call(peer, Application, :put_all_env, [config, [persistent: true]])

    repo_config =
      Application.fetch_env!(:marshall, Repo)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 4)

    for {key, value} <- [
          {Repo, repo_config},
          {:github_provider, Marshall.GitHubTestProvider},
          {:github_client_id, "synthetic-client"},
          {:github_client_secret_file, "/unused-test-path"},
          {:github_redirect_uri, "https://example.test/auth/github-com/callback"}
        ] do
      :ok = :peer.call(peer, Application, :put_env, [:marshall, key, value, [persistent: true]])
    end

    :ok = :peer.call(peer, Application, :put_env, [:logger, :level, :error, [persistent: true]])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:marshall], 30_000)
    peer
  end

  # @cc [owner:ghuntley,label:verification] github-observer-authenticated-distribution
  # Gate notifications MUST use authenticated native node connections. The
  # observer MUST NOT count among the three authority replicas; fixture cookies
  # MUST remain in memory and MUST NOT enter diagnostic output.
  @spec connect_observer!(pid()) :: :ok
  defp connect_observer!(peer) do
    peer_node = :peer.call(peer, :erlang, :node, [])
    cookie = :peer.call(peer, :erlang, :get_cookie, [])
    true = Node.set_cookie(peer_node, cookie)
    true = Node.connect(peer_node)
    :ok
  end
end
