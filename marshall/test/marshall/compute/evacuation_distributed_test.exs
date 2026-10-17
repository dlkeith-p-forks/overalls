defmodule Marshall.Compute.EvacuationDistributedTest do
  use ExUnit.Case, async: false
  alias Marshall.Accounts.Security
  alias Marshall.EvacuationHistoryFixture, as: Fixture
  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification] evacuation-three-independent-peers
  # Every schedule MUST use three distinct Marshall BEAMs and Repo pools; the
  # coordinator MUST NOT count as one of those instances.
  setup_all do
    # Separate BEAMs, Repo pools and Cedar handles share only PostgreSQL. The
    # parent test node is not counted among the three control-plane instances.
    peers =
      Enum.map(
        [
          :marshall_evacuation_1,
          :marshall_evacuation_2,
          :marshall_evacuation_3
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

  for command <- [:request, :pause, :approve, :replan],
      competitor <- [:lock, :signout],
      order <- [:control_first, :lock_first] do
    @command command
    @competitor competitor
    @order order
    @tag evacuation_request_authority: command == :request
    test "campaign #{@command} and #{@competitor} serialize #{@order}", %{peers: peers} do
      overlap(@command, @competitor, @order, peers)
    end
  end

  @spec overlap(
          :request | :pause | :approve | :replan,
          :lock | :signout,
          :control_first | :lock_first,
          [
            pid()
          ]
        ) :: :ok
  defp overlap(command, competitor, order, [first, second, third]) do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      source = Marshall.ComputeFixtures.host_fixture()
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))

      if command in [:request, :approve, :replan], do: Fixture.workload(admin)

      campaign =
        if command == :request do
          %{id: Ash.UUID.generate()}
        else
          {:ok, accepted} = Fixture.request(source.host.id, Ash.UUID.generate(), admin)
          accepted
        end

      operation = fn peer, command ->
        if command == :request,
          do: remote(peer, Fixture, :request, [source.host.id, campaign.id, admin], 30_000),
          else: remote(peer, Fixture, :act, [command, campaign.id, admin], 30_000)
      end

      leading = if order == :control_first, do: command, else: competitor
      following = if order == :control_first, do: competitor, else: command
      gate = System.unique_integer([:positive])

      Fixture.with_cleanup(source.host, admin, fn ->
        before = :peer.call(third, Fixture, :snapshot, [source.host.id, campaign.id])
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])
        Fixture.install_gate(leading, campaign.id, admin.id, gate)

        try do
          {one, {two, observed}} =
            guarded(
              supervisor,
              first,
              gate,
              fn -> operation.(first, leading) end,
              fn ->
                holder = await_gate(gate)

                assert :peer.call(third, Fixture, :snapshot, [source.host.id, campaign.id]) ==
                         before

                guarded(
                  supervisor,
                  second,
                  gate,
                  fn ->
                    operation.(second, following)
                  end,
                  fn ->
                    await_ordering(holder, third, source.host.id, campaign.id, admin, before)
                  end
                )
              end
            )

          {control, lock} = if order == :control_first, do: {one, two}, else: {two, one}
          assert observed == :blocked
          assert {:ok, _} = lock

          if order == :control_first do
            assert {:ok, _} = control
          else
            assert {:error, _} = control
            assert :peer.call(third, Fixture, :snapshot, [source.host.id, campaign.id]) == before
          end

          final = :peer.call(third, Fixture, :snapshot, [source.host.id, campaign.id])

          for peer <- [first, second, third] do
            assert :peer.call(peer, Fixture, :snapshot, [source.host.id, campaign.id]) == final

            assert {:completed, {:ok, {:error, _}}} =
                     remote(peer, Fixture, :act, [:continue, campaign.id, admin], 30_000)

            assert :peer.call(peer, Fixture, :snapshot, [source.host.id, campaign.id]) == final
          end

          :ok
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
          Fixture.remove_gate(leading, campaign.id)
        end
      end)
    end)
  end

  for schedule <- [:pause_first, :advance_first, :duplicate_worker, :duplicate_request] do
    @schedule schedule
    test "campaign and worker serialization #{@schedule}", %{peers: [first, second, third]} do
      supervisor = start_supervised!(Task.Supervisor)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        source = Marshall.ComputeFixtures.host_fixture()
        admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
        vm = Fixture.workload(admin)
        destination = Marshall.ComputeFixtures.host_fixture()

        Fixture.with_cleanup([source.host, destination.host], admin, fn ->
          id = Ash.UUID.generate()

          unless @schedule == :duplicate_request do
            assert {:ok, _} = Fixture.request(source.host.id, id, admin)
            # Running guests always need downtime consent before a move (ADR-0155).
            assert {:ok, _} = Fixture.act(:approve, id, admin)
          end

          {leading, following} =
            case @schedule do
              :pause_first -> {:pause, :advance}
              :advance_first -> {:advance, :pause}
              :duplicate_worker -> {:advance, :advance}
              :duplicate_request -> {:request, :request}
            end

          operation = fn peer, command ->
            if command == :request,
              do: remote(peer, Fixture, :request, [source.host.id, id, admin], 30_000),
              else: remote(peer, Fixture, :act, [command, id, admin], 30_000)
          end

          gate = System.unique_integer([:positive])
          before = :peer.call(third, Fixture, :snapshot, [source.host.id, id])
          Fixture.query("SELECT pg_advisory_lock($1)", [gate])
          Fixture.install_gate(leading, id, admin.id, gate)

          try do
            {one, {two, :blocked}} =
              guarded(supervisor, first, gate, fn -> operation.(first, leading) end, fn ->
                holder = await_gate(gate)
                assert :peer.call(third, Fixture, :snapshot, [source.host.id, id]) == before

                guarded(supervisor, second, gate, fn -> operation.(second, following) end, fn ->
                  await_ordering(holder, third, source.host.id, id, admin, before)
                end)
              end)

            case @schedule do
              :pause_first ->
                assert {:ok, %{status: :paused}} = one
                assert {:ok, :paused} = two

                assert [] ==
                         Marshall.Compute.Ledger.read!(Marshall.Compute.Relocation,
                           evacuation_id: id
                         )

              :advance_first ->
                assert {:ok, :scheduled} = one
                assert {:ok, %{status: :paused}} = two

              :duplicate_worker ->
                assert {:ok, :scheduled} = one
                assert {:ok, :already_scheduled} = two

              :duplicate_request ->
                assert {:ok, campaign} = one
                assert {:ok, ^campaign} = two
            end

            [item] =
              Marshall.Compute.Ledger.read!(Marshall.Compute.EvacuationItem, evacuation_id: id)

            assert item.vm_id == vm.id and item.placement_id == vm.current_placement_id
            moves = Marshall.Compute.Ledger.read!(Marshall.Compute.Relocation, evacuation_id: id)

            if @schedule in [:advance_first, :duplicate_worker] do
              assert [move] = moves
              assert item.relocation_id == move.id

              assert length(
                       Marshall.Compute.Ledger.read!(Marshall.Compute.Reservation, vm_id: vm.id)
                     ) == 2

              assert length(
                       Marshall.Compute.Ledger.read!(Marshall.Compute.TransferSlot,
                         source_relocation_id: move.id
                       )
                     ) == 1

              assert length(
                       Marshall.Compute.Ledger.read!(Marshall.Compute.TransferSlot,
                         destination_relocation_id: move.id
                       )
                     ) == 1
            else
              assert moves == [] and item.relocation_id == nil
            end

            [audit] =
              Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminEvent,
                target_id: id,
                kind: :evacuation_request
              )

            assert audit.actor_id == admin.id
            final = :peer.call(third, Fixture, :snapshot, [source.host.id, id])
            assert :peer.call(first, Fixture, :snapshot, [source.host.id, id]) == final
            assert :peer.call(second, Fixture, :snapshot, [source.host.id, id]) == final
          after
            Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
            Fixture.remove_gate(leading, id)
          end
        end)
      end)
    end
  end

  @tag :evacuation_lock_order
  test "evacuation approval retains VM-before-User order with personal identity allocation", %{
    peers: [first, second, third]
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      agents_before = Fixture.agent_inventory()
      source = Marshall.ComputeFixtures.host_fixture()
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      vm = Fixture.workload(admin)

      {:ok, campaign} =
        Marshall.Compute.request_evacuation(
          %{host_id: source.host.id, request_id: Ash.UUID.generate()},
          actor: admin
        )

      gate = System.unique_integer([:positive])

      Fixture.with_cleanup(source.host, admin, fn ->
        try do
          Fixture.query("SELECT pg_advisory_lock($1)", [gate])

          {identity, {approval, :blocked}} =
            guarded(
              supervisor,
              first,
              gate,
              fn -> remote(first, Fixture, :guest_identity, [vm.id, admin.id, gate], 30_000) end,
              fn ->
                holder = await_gate(gate)

                guarded(
                  supervisor,
                  second,
                  gate,
                  fn -> remote(second, Fixture, :act, [:approve, campaign.id, admin], 30_000) end,
                  fn ->
                    await(
                      fn ->
                        Fixture.query("SELECT pg_stat_clear_snapshot()")

                        # Match the actual transaction owning the VM, excluding queue-only blockers.
                        result =
                          Fixture.query(
                            "SELECT count(*) FROM pg_locks waiter JOIN pg_locks owner ON waiter.locktype='transactionid' AND owner.locktype='transactionid' AND waiter.transactionid=owner.transactionid WHERE NOT waiter.granted AND owner.granted AND owner.pid=$1",
                            [holder]
                          ).rows

                        if result == [[1]], do: {:ok, :blocked}, else: :wait
                      end,
                      "Evacuation did not wait for the actual VM owner"
                    )
                  end
                )
              end
            )

          assert {:ok, identity_id} = identity
          assert is_binary(identity_id)
          assert {:ok, %{approved: true}} = approval
          snapshot = :peer.call(third, Fixture, :snapshot, [source.host.id, campaign.id])
          assert snapshot == :peer.call(first, Fixture, :snapshot, [source.host.id, campaign.id])
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
        end
      end)

      assert Fixture.agent_inventory() == agents_before
    end)
  end

  @tag :evacuation_failure_cleanup
  test "a failed in-flight assertion releases gates and drains both mutations before cleanup", %{
    peers: [first, second, third]
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      agents_before = Fixture.agent_inventory()
      source = Marshall.ComputeFixtures.host_fixture()
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      vm = Fixture.workload(admin)

      {:ok, campaign} =
        Marshall.Compute.request_evacuation(
          %{host_id: source.host.id, request_id: Ash.UUID.generate()},
          actor: admin
        )

      gate = System.unique_integer([:positive])

      assert_raise ExUnit.AssertionError, ~r/intentional evacuation gate assertion/, fn ->
        Fixture.with_cleanup(source.host, admin, fn ->
          assert %{rows: [[1]]} =
                   Fixture.query("SELECT count(*) FROM agent_roots WHERE vm_id=$1", [
                     Ecto.UUID.dump!(vm.id)
                   ])

          before = :peer.call(third, Fixture, :snapshot, [source.host.id, campaign.id])
          Fixture.query("SELECT pg_advisory_lock($1)", [gate])
          Fixture.install_gate(:pause, campaign.id, admin.id, gate)

          try do
            guarded(
              supervisor,
              first,
              gate,
              fn -> remote(first, Fixture, :act, [:pause, campaign.id, admin], 30_000) end,
              fn ->
                holder = await_gate(gate)

                guarded(
                  supervisor,
                  second,
                  gate,
                  fn -> remote(second, Fixture, :act, [:lock, campaign.id, admin], 30_000) end,
                  fn ->
                    assert await_ordering(
                             holder,
                             third,
                             source.host.id,
                             campaign.id,
                             admin,
                             before
                           ) == :blocked

                    flunk("intentional evacuation gate assertion")
                  end
                )
              end
            )
          after
            Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
            Fixture.remove_gate(:pause, campaign.id)
          end
        end)
      end

      assert %{rows: [[0]]} =
               Fixture.query("SELECT count(*) FROM compute_hosts WHERE id=$1", [
                 Ecto.UUID.dump!(source.host.id)
               ])

      assert %{rows: [[0]]} =
               Fixture.query("SELECT count(*) FROM compute_evacuations WHERE id=$1", [
                 Ecto.UUID.dump!(campaign.id)
               ])

      assert %{rows: [[0]]} =
               Fixture.query("SELECT count(*) FROM users WHERE id=$1", [Ecto.UUID.dump!(admin.id)])

      assert Fixture.agent_inventory() == agents_before

      assert %{rows: [[0]]} =
               Fixture.query(
                 "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid=$1",
                 [gate]
               )
    end)
  end

  @spec await_ordering(
          integer(),
          pid(),
          String.t(),
          String.t(),
          Marshall.Accounts.User.t(),
          Fixture.snapshot()
        ) :: atom()
  defp await_ordering(holder, observer, host, campaign, admin, before) do
    await(
      fn ->
        Fixture.query("SELECT pg_stat_clear_snapshot()")

        blocked =
          Fixture.query(
            "SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
            [holder]
          ).rows

        cond do
          blocked == [[1]] ->
            {:ok, :blocked}

          not :peer.call(observer, Security, :recent?, [admin]) ->
            {:ok, :authority_overtook}

          :peer.call(observer, Fixture, :snapshot, [host, campaign]) != before ->
            {:ok, :write_overtook}

          true ->
            :wait
        end
      end,
      "Competing evacuation operation neither blocked nor committed"
    )
  end

  @typep outcome ::
           {:ok, term()} | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  # @cc [owner:ghuntley,label:verification] evacuation-failed-gate-cleanup
  # Any failed assertion MUST release the gate and drain both production calls
  # before fixture deletion. An unresponsive peer MUST be stopped before cleanup;
  # the original assertion MUST remain the failure reported to the test runner.
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
        try do
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
        after
          send(self(), {receipt, drain(supervisor, peer, task)})
        end
      end

    receive do
      {^receipt, task_result} ->
        value = result!(result)
        {result!(task_result), value}
    end
  end

  @spec remote(pid(), module(), atom(), [term()], pos_integer()) ::
          {:completed, Marshall.JobHistoryFixture.outcome()}
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

  @spec await_gate(integer()) :: integer()
  defp await_gate(gate) do
    await(
      fn ->
        case Fixture.query(
               "SELECT pid FROM pg_locks WHERE locktype='advisory' AND objid=$1 AND NOT granted",
               [gate]
             ).rows do
          [[pid]] -> {:ok, pid}
          [] -> :wait
        end
      end,
      "Production operation did not reach its target write gate"
    )
  end

  @spec await((-> {:ok, value} | :wait), String.t(), non_neg_integer()) :: value
        when value: term()
  defp await(probe, message, attempts \\ 150)
  defp await(_probe, message, 0), do: flunk(message)

  defp await(probe, message, attempts) do
    case probe.() do
      {:ok, value} ->
        value

      :wait ->
        receive do
        after
          20 -> await(probe, message, attempts - 1)
        end
    end
  end
end
