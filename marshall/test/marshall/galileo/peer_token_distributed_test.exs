defmodule Marshall.Galileo.PeerTokenDistributedTest do
  use ExUnit.Case, async: false
  require Marshall.CommittedFixtureCleanup, as: Cleanup
  alias Marshall.Galileo
  alias Marshall.Galileo.PeerTokens
  alias Marshall.GalileoPeerFixture, as: Fixture
  alias Marshall.Repo
  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification] committed-fixture-suite-preservation
  # Every journey MUST restore its complete pre-test row inventory, including
  # historical rows. ExUnit reports this independent teardown check separately
  # from a body failure; it MUST NOT replace the original assertion.
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

  # @cc [owner:ghuntley,label:verification] peer-token-three-independent-replicas
  # One-use provenance MUST be exercised by three fresh Marshall BEAMs with
  # separate Repo pools against committed state; the runner is not a replica.
  setup_all do
    # Separate BEAMs, Repo pools and Cedar handles share only PostgreSQL. The
    # parent test node is not counted among the three control-plane instances.
    peers =
      Enum.map(
        [:marshall_peer_renewal_1, :marshall_peer_renewal_2, :marshall_peer_renewal_3],
        fn name ->
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

          node = :peer.call(peer, :erlang, :node, [])
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

          :ok =
            :peer.call(peer, Application, :put_env, [
              :marshall,
              Repo,
              repo_config,
              [persistent: true]
            ])

          :ok =
            :peer.call(peer, Application, :put_env, [:logger, :level, :error, [persistent: true]])

          {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:marshall], 30_000)
          {peer, node}
        end
      )

    assert length(Enum.uniq(Enum.map(peers, &elem(&1, 1)))) == 3
    %{peers: Enum.map(peers, &elem(&1, 0))}
  end

  # @cc [owner:ghuntley,label:verification] peer-token-real-consumer-ordering
  # The race MUST hold only the existing token row, observe three production
  # DELETE consumers actually waiting in PostgreSQL, then release them. Exactly
  # one closed attestation and two refusals MUST agree with an independent
  # durable row-count oracle. All task calls MUST drain before fixture cleanup.
  test "three replicas consume one committed peer token exactly once", %{peers: peers} do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      fixture = Fixture.create()

      Cleanup.protect peers do
        token = PeerTokens.mint(fixture.vm.id, fixture.integration.id, fixture.integration.name)
        digest = :crypto.hash(:sha256, token)
        assert :peer.call(List.last(peers), Fixture, :token_count, [fixture.integration.id]) == 1

        tasks =
          Repo.transaction(fn ->
            %{num_rows: 1} =
              Repo.query!(
                "SELECT id FROM galileo_peer_tokens WHERE digest=$1 FOR UPDATE",
                [digest],
                log: false
              )

            tasks =
              Enum.map(peers, fn peer ->
                Task.Supervisor.async_nolink(supervisor, fn ->
                  :peer.call(peer, PeerTokens, :verify, [token], 30_000)
                end)
              end)

            try do
              await_consumers(3)
              assert Fixture.token_count(fixture.integration.id) == 1
              tasks
            rescue
              exception ->
                # Rollback releases the row before the caller drains consumers.
                Repo.rollback({:fixture_error, exception, __STACKTRACE__, tasks})
            end
          end)

        results = drain(tasks, peers)
        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &(&1 == {:error, :invalid_peer_token})) == 2
        [{:ok, attestation}] = Enum.filter(results, &match?({:ok, _}, &1))

        assert Map.keys(attestation) |> Enum.sort() == [
                 :expires_at,
                 :integration_id,
                 :name,
                 :source_vm_id
               ]

        assert attestation.source_vm_id == fixture.vm.id
        assert attestation.integration_id == fixture.integration.id
        assert attestation.name == fixture.integration.name
        assert is_integer(attestation.expires_at)

        for peer <- peers do
          assert :peer.call(peer, Fixture, :token_count, [fixture.integration.id]) == 0
          assert :peer.call(peer, PeerTokens, :verify, [token]) == {:error, :invalid_peer_token}
        end
      after
        Fixture.cleanup(fixture)
      end
    end)
  end

  test "expiry and integration archive refuse on every replica without consuming another token",
       %{peers: peers} do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      fixture = Fixture.create()

      Cleanup.protect peers do
        expired = PeerTokens.mint(fixture.vm.id, fixture.integration.id, fixture.integration.name)

        Repo.query!(
          "UPDATE galileo_peer_tokens SET expires_at=clock_timestamp()-interval '1 second' WHERE digest=$1",
          [:crypto.hash(:sha256, expired)],
          log: false
        )

        for peer <- peers,
            do:
              assert(
                :peer.call(peer, PeerTokens, :verify, [expired]) == {:error, :invalid_peer_token}
              )

        assert Fixture.token_count(fixture.integration.id) == 1
        fresh = PeerTokens.mint(fixture.vm.id, fixture.integration.id, fixture.integration.name)
        assert Fixture.token_count(fixture.integration.id) == 1

        assert {:ok, _} =
                 :peer.call(hd(peers), Galileo, :remove_integration, [
                   %{name: fixture.integration.name},
                   [actor: fixture.owner]
                 ])

        for peer <- peers do
          assert :peer.call(peer, PeerTokens, :verify, [fresh]) == {:error, :invalid_peer_token}
          assert :peer.call(peer, Fixture, :token_count, [fixture.integration.id]) == 1
        end
      after
        Fixture.cleanup(fixture)
      end
    end)
  end

  @spec drain({:ok, [Task.t()]} | {:error, term()}, [pid()]) :: [term()]
  defp drain({:ok, tasks}, peers), do: drain_tasks(tasks, peers)

  defp drain({:error, {:fixture_error, exception, stack, tasks}}, peers) do
    drain_tasks(tasks, peers)
    reraise exception, stack
  end

  @spec drain_tasks([Task.t()], [pid()]) :: [term()]
  defp drain_tasks(tasks, peers) do
    outcomes = Task.yield_many(tasks, 35_000)
    # A killed RPC caller alone does not stop its remote database operation.
    # Stop any unresponsive peer before teardown can touch its fixture rows.
    for {{task, outcome}, peer} <- Enum.zip(outcomes, peers),
        not match?({:ok, _}, outcome) do
      :peer.stop(peer)
      Task.shutdown(task, :brutal_kill)
    end

    assert Enum.all?(outcomes, fn {_task, outcome} -> match?({:ok, _}, outcome) end),
           "A remote token consumer did not finish"

    Enum.map(outcomes, fn {_task, {:ok, value}} -> value end)
  end

  @spec await_consumers(non_neg_integer(), non_neg_integer()) :: :ok
  defp await_consumers(expected, attempts \\ 150)

  defp await_consumers(_expected, 0),
    do: flunk("Three production peer consumers did not block on the committed token")

  defp await_consumers(expected, attempts) do
    Repo.query!("SELECT pg_stat_clear_snapshot()", [], log: false)

    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE 'DELETE FROM galileo_peer_tokens AS token%'",
        [],
        log: false
      )

    if count == expected do
      :ok
    else
      receive do
      after
        20 -> await_consumers(expected, attempts - 1)
      end
    end
  end
end
