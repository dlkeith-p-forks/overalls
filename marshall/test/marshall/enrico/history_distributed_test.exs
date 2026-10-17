defmodule Marshall.Enrico.HistoryDistributedTest do
  use ExUnit.Case, async: false
  alias Marshall.CommittedFixtureCleanup, as: Cleanup
  require Cleanup
  alias Marshall.Repo
  alias Marshall.Compute.Ledger
  alias Marshall.Enrico.{Catalog, Repository, Worker}
  alias Marshall.EnricoHistoryFixture, as: Fixture
  @moduletag :distributed
  @moduletag timeout: 120_000
  @moduletag :tmp_dir
  @tls Path.expand("../../fixtures/tls", __DIR__)

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

  setup_all do
    # Separate BEAMs, Repo pools and Cedar handles share only PostgreSQL. The
    # parent test node is not counted among the three control-plane instances.
    peers =
      Enum.map(
        [
          :marshall_enrico_history_1,
          :marshall_enrico_history_2,
          :marshall_enrico_history_3
        ],
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

  setup %{peers: peers, tmp_dir: dir} do
    server =
      start_supervised!(
        {Bandit,
         plug: {Fixture, owner: self()},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@tls, "localhost.pem"),
         keyfile: Path.join(@tls, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    token_file = Path.join(dir, "token")
    File.write!(token_file, String.duplicate("a", 32))

    for peer <- peers,
        {key, value} <- [
          enrico_url: "https://localhost:#{port}",
          enrico_token_file: token_file,
          enrico_ca_file: Path.join(@tls, "ca.pem")
        ] do
      :ok = :peer.call(peer, Application, :put_env, [:marshall, key, value])
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification] enrico-removal-outcome-ordering
  # A real worker response delayed until after public removal MUST NOT restore
  # browseability or append a success receipt. Three independent BEAMs observe
  # the committed result; the HTTP fixture supplies no catalog state transitions.
  test "removal wins over a delayed successful refresh result", %{
    peers: [worker, admin_peer, observer] = peers
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))

      Cleanup.protect peers do
        {:ok, repo} =
          :peer.call(admin_peer, Fixture, :register, [admin, "r-" <> Ash.UUID.generate()])

        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            remote(worker, Worker, :perform, [%Oban.Job{args: %{"id" => repo.id}}], 35_000)
          end)

        receipt = make_ref()

        attempt =
          try do
            assert_receive {:attempt_waiting, responder, id, attempt}, 10_000

            try do
              assert id == repo.id
              assert :ok = :peer.call(admin_peer, Catalog, :remove, [admin, repo.id])

              assert %{repositories: [%{phase: :removing}]} =
                       :peer.call(observer, Fixture, :snapshot, [repo.id])

              assert nil == :peer.call(observer, Catalog, :get, [admin, repo.owner, repo.name])
              attempt
            after
              Fixture.complete(responder, %{state: "succeeded", head: String.duplicate("b", 40)})
            end
          after
            send(self(), {receipt, drain(supervisor, worker, task)})
          end

        outcome =
          receive do
            {^receipt, value} -> value
          end

        final = :peer.call(observer, Fixture, :snapshot, [repo.id])
        assert [%{phase: :removing, head: nil, attempt_id: ^attempt}] = final.repositories
        refute Enum.any?(final.events, &(&1.kind == :refresh_succeeded))
        assert {:ok, :ok} = outcome
      after
        Fixture.cleanup([admin])
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification] enrico-admin-transaction-ordering
  # A demotion concurrent with a gated public registration MUST serialize behind
  # its authority transaction. No catalog, job or audit row may appear early.
  test "administrator demotion cannot overtake an admitted catalog write", %{
    peers: [mutation, authority, observer] = peers
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      actor = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      gate = System.unique_integer([:positive])
      Fixture.query("SELECT pg_advisory_lock($1)", [gate])
      Fixture.install_gate(actor.id, gate)
      name = "r-" <> Ash.UUID.generate()

      Cleanup.protect peers do
        {registration, {demotion, ordering}} =
          guarded(
            supervisor,
            mutation,
            gate,
            fn -> remote(mutation, Fixture, :register, [actor, name], 30_000) end,
            fn ->
              holder =
                await(fn ->
                  case Fixture.query(
                         "SELECT pid FROM pg_locks WHERE locktype='advisory' AND objid=$1 AND NOT granted",
                         [gate]
                       ).rows do
                    [[pid]] -> {:ok, pid}
                    [] -> :wait
                  end
                end)

              assert Ledger.read!(Repository, registered_by_id: actor.id) == []

              guarded(
                supervisor,
                authority,
                gate,
                fn -> remote(authority, Fixture, :demote, [admin, actor], 30_000) end,
                fn ->
                  await(fn ->
                    blocked =
                      Fixture.query(
                        "SELECT count(*) FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid))",
                        [holder]
                      ).rows

                    cond do
                      blocked != [[0]] ->
                        {:ok, :serialized}

                      not :peer.call(observer, Fixture, :current_admin?, [actor.id]) ->
                        {:ok, :overtook}

                      true ->
                        :wait
                    end
                  end)
                end
              )
            end
          )

        assert {:ok, repo} = registration
        assert {:ok, %{administrator: false}} = demotion
        assert ordering == :serialized
        assert [%{id: id}] = Ledger.read!(Repository, registered_by_id: actor.id)
        assert id == repo.id
        assert {:error, :forbidden} = :peer.call(mutation, Catalog, :refresh, [actor, repo.id])
      after
        Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
        Fixture.remove_gate(actor.id)
        Fixture.cleanup([actor, admin])
      end
    end)
  end

  test "catalog action waiting behind administrator demotion rechecks authority", %{
    peers: [authority, mutation, observer] = peers
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      actor = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      gate = System.unique_integer([:positive])
      Fixture.query("SELECT pg_advisory_lock($1)", [gate])
      Fixture.install_gate(actor.id, gate, :demotion)

      Cleanup.protect peers do
        {demotion, {registration, ordering}} =
          guarded(
            supervisor,
            authority,
            gate,
            fn -> remote(authority, Fixture, :demote, [admin, actor], 30_000) end,
            fn ->
              holder =
                await(fn ->
                  case Fixture.query(
                         "SELECT pid FROM pg_locks WHERE locktype='advisory' AND objid=$1 AND NOT granted",
                         [gate]
                       ).rows do
                    [[pid]] -> {:ok, pid}
                    [] -> :wait
                  end
                end)

              guarded(
                supervisor,
                mutation,
                gate,
                fn ->
                  remote(
                    mutation,
                    Fixture,
                    :register,
                    [actor, "r-" <> Ash.UUID.generate()],
                    30_000
                  )
                end,
                fn ->
                  await(fn ->
                    blocked =
                      Fixture.query(
                        "SELECT count(*) FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid))",
                        [holder]
                      ).rows

                    cond do
                      blocked != [[0]] ->
                        {:ok, :serialized}

                      :peer.call(observer, Ledger, :read!, [
                        Repository,
                        [registered_by_id: actor.id]
                      ]) != [] ->
                        {:ok, :overtook}

                      true ->
                        :wait
                    end
                  end)
                end
              )
            end
          )

        assert {:ok, %{administrator: false}} = demotion
        assert ordering == :serialized
        assert {:error, :forbidden} = registration
        assert Ledger.read!(Repository, registered_by_id: actor.id) == []
        assert Ledger.read!(Marshall.Enrico.AuditEvent, actor_id: actor.id) == []
      after
        Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
        Fixture.remove_gate(actor.id, :demotion)
        Fixture.cleanup([actor, admin])
      end
    end)
  end

  test "duplicate workers settling one attempt append one outcome", %{
    peers: [first, second, observer] = peers
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))

      Cleanup.protect peers do
        {:ok, repo} =
          :peer.call(observer, Fixture, :register, [admin, "r-" <> Ash.UUID.generate()])

        status = %{state: "succeeded", head: String.duplicate("c", 40)}

        {first_result, {second_result, attempt}} =
          controlled_worker(supervisor, first, repo.id, fn first_reply, attempt, first_monitor ->
            controlled_worker(supervisor, second, repo.id, fn status_reply, ^attempt, _ ->
              Fixture.complete(status_reply, "running")
              assert_receive {:attempt_waiting, second_reply, _, ^attempt}, 10_000

              try do
                Fixture.complete(first_reply, status)
                assert_receive {:DOWN, ^first_monitor, :process, _, _}, 10_000
                attempt
              after
                Fixture.complete(second_reply, status)
              end
            end)
          end)

        assert first_result == :ok
        assert second_result == :ok
        snapshot = :peer.call(observer, Fixture, :snapshot, [repo.id])
        assert [%{phase: :ready, attempt_id: ^attempt, head: head}] = snapshot.repositories
        assert head == status.head

        assert Enum.count(
                 snapshot.events,
                 &(&1.kind == :refresh_succeeded and &1.attempt_id == attempt)
               ) == 1
      after
        Fixture.cleanup([admin])
      end
    end)
  end

  @typep outcome ::
           {:ok, term()} | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  for result <- [:success, :failure] do
    @result result
    test "a replaced attempt cannot settle #{@result} over the current refreshing attempt", %{
      peers: [first, second, observer] = peers
    } do
      supervisor = start_supervised!(Task.Supervisor)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))

        Cleanup.protect peers do
          {:ok, repo} =
            :peer.call(observer, Fixture, :register, [admin, "r-" <> Ash.UUID.generate()])

          {first_result, {second_result, new_attempt}} =
            controlled_worker(supervisor, first, repo.id, fn old_responder,
                                                             old_attempt,
                                                             old_monitor ->
              controlled_worker(supervisor, second, repo.id, fn status_responder,
                                                                queried_attempt,
                                                                _monitor ->
                assert queried_attempt == old_attempt
                Fixture.complete(status_responder, "missing")
                assert_receive {:attempt_waiting, new_responder, id, new_attempt}, 10_000

                try do
                  assert id == repo.id
                  refute new_attempt == old_attempt

                  Fixture.complete(
                    old_responder,
                    if(@result == :success,
                      do: %{state: "succeeded", head: String.duplicate("a", 40)},
                      else: "failed"
                    )
                  )

                  assert_receive {:DOWN, ^old_monitor, :process, _, _}, 10_000
                  snapshot = :peer.call(observer, Fixture, :snapshot, [repo.id])

                  assert [%{phase: :refreshing, head: nil, attempt_id: ^new_attempt}] =
                           snapshot.repositories

                  refute Enum.any?(snapshot.events, &(&1.kind == :refresh_succeeded))

                  assert Enum.count(
                           snapshot.events,
                           &(&1.kind == :refresh_failed and &1.attempt_id == old_attempt)
                         ) == 1

                  new_attempt
                after
                  Fixture.complete(new_responder, %{
                    state: "succeeded",
                    head: String.duplicate("b", 40)
                  })
                end
              end)
            end)

          assert first_result == :ok
          assert second_result == :ok
          snapshot = :peer.call(observer, Fixture, :snapshot, [repo.id])
          assert [%{phase: :ready, attempt_id: ^new_attempt, head: head}] = snapshot.repositories
          assert head == String.duplicate("b", 40)

          assert Enum.count(
                   snapshot.events,
                   &(&1.kind == :refresh_succeeded and &1.attempt_id == new_attempt)
                 ) == 1
        after
          Fixture.cleanup([admin])
        end
      end)
    end
  end

  @spec controlled_worker(pid(), pid(), String.t(), (Fixture.responder(),
                                                     String.t(),
                                                     reference() ->
                                                       result)) ::
          {term(), result}
        when result: term()
  defp controlled_worker(supervisor, peer, id, body) do
    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        remote(peer, Worker, :perform, [%Oban.Job{args: %{"id" => id}}], 35_000)
      end)

    monitor = Process.monitor(task.pid)
    receipt = make_ref()

    result =
      try do
        assert_receive {:attempt_waiting, responder, ^id, attempt}, 10_000

        try do
          {:ok, body.(responder, attempt, monitor)}
        after
          Fixture.complete(responder, "failed")
        end
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      after
        send(self(), {receipt, drain(supervisor, peer, task)})
        Process.demonitor(monitor, [:flush])
      end

    receive do
      {^receipt, task_result} ->
        value = result!(result)
        {result!(task_result), value}
    end
  end

  @spec guarded(pid(), pid(), integer(), (-> term()), (-> result)) :: {term(), result}
        when result: term()
  defp guarded(supervisor, peer, gate, operation, body) do
    task = Task.Supervisor.async_nolink(supervisor, operation)
    receipt = make_ref()

    result =
      try do
        {:ok, body.()}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      after
        Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
        send(self(), {receipt, drain(supervisor, peer, task)})
      end

    receive do
      {^receipt, task_result} -> {result!(task_result), result!(result)}
    end
  end

  @spec remote(pid(), module(), atom(), [term()], pos_integer()) ::
          {:completed, Fixture.outcome()}
  defp remote(peer, module, function, arguments, timeout),
    do: :peer.call(peer, Fixture, :invoke, [module, function, arguments], timeout)

  @spec drain(pid(), pid(), Task.t()) :: outcome()
  defp drain(supervisor, peer, task) do
    case Task.yield(task, 40_000) do
      {:ok, {:completed, outcome}} ->
        outcome

      {:ok, _unknown} ->
        :peer.stop(peer)
        {:raised, :exit, :unknown_remote_completion, []}

      {:exit, reason} ->
        :peer.stop(peer)
        {:raised, :exit, reason, []}

      nil ->
        Task.Supervisor.terminate_child(supervisor, task.pid)
        :peer.stop(peer)
        {:raised, :exit, :remote_timeout, []}
    end
  end

  @spec result!(outcome()) :: term()
  defp result!({:ok, value}), do: value
  defp result!({:raised, kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)

  @spec await((-> {:ok, value} | :wait), non_neg_integer()) :: value when value: term()
  defp await(probe, attempts \\ 200)

  defp await(_probe, 0),
    do: flunk("Neither committed outcome nor PostgreSQL blocking relationship observed")

  defp await(probe, attempts) do
    case probe.() do
      {:ok, value} ->
        value

      :wait ->
        receive do
        after
          20 -> await(probe, attempts - 1)
        end
    end
  end
end
