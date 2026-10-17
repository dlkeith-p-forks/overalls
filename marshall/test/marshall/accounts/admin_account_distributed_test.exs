defmodule Marshall.Accounts.AdminAccountDistributedTest do
  use ExUnit.Case, async: false
  alias Marshall.Accounts.Security
  alias Marshall.AdminAccountFixture, as: Fixture
  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification] admin-account-three-independent-peers
  # Every schedule MUST use three distinct Marshall BEAMs and Repo pools; the
  # coordinator MUST NOT count as one of those instances.
  setup_all do
    # Separate BEAMs, Repo pools and Cedar handles share only PostgreSQL. The
    # parent test node is not counted among the three control-plane instances.
    peers =
      Enum.map(
        [
          :marshall_admin_account_1,
          :marshall_admin_account_2,
          :marshall_admin_account_3
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

  for operation <- [:role, :sessions, :reset, :retire, :invite],
      competitor <- [:lock, :signout],
      order <- [:mutation_first, :revocation_first] do
    @operation operation
    @competitor competitor
    @order order
    test "#{@operation} versus #{@competitor} #{@order}", %{peers: peers} do
      overlap(@operation, @competitor, @order, peers)
    end
  end

  test "completed revocation refuses fresh mutations on every peer without a gate", %{
    peers: peers
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      for competitor <- [:lock, :signout] do
        actor = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
        target = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user())

        try do
          first = hd(peers)

          task =
            Task.Supervisor.async_nolink(supervisor, fn ->
              remote(first, Fixture, :act, [competitor, actor, target], 30_000)
            end)

          assert {:ok, _} = result!(drain(supervisor, first, task))
          before = Fixture.snapshot(actor, target)

          for peer <- peers, operation <- [:role, :sessions, :reset, :retire, :invite] do
            task =
              Task.Supervisor.async_nolink(supervisor, fn ->
                remote(peer, Fixture, :act, [operation, actor, target], 30_000)
              end)

            assert {:error, _} = result!(drain(supervisor, peer, task))
            assert :peer.call(peer, Fixture, :snapshot, [actor, target]) == before
          end
        after
          Fixture.cleanup([actor, target])
        end
      end
    end)
  end

  test "existing retirement receipt waits and rechecks a preceding elevation lock", %{
    peers: peers
  } do
    overlap(:retire, :lock, :revocation_first, peers, true)
  end

  test "retirement actor lock does not deadlock unrelated team membership", %{
    peers: [first, second, third]
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      actor = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      target = Marshall.PasskeyFixture.user()
      unrelated = Marshall.PasskeyFixture.user()

      {:ok, team} =
        Marshall.Teams.create_team(
          %{name: "account-cycle-" <> Ash.UUID.generate(), idempotency_key: Ash.UUID.generate()},
          actor: actor
        )

      assert {:ok, _} = Fixture.add_member(actor, target, team.id)
      gate = System.unique_integer([:positive])

      try do
        before = :peer.call(third, Fixture, :snapshot, [actor, target])
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])
        Fixture.install_gate(:team_member, unrelated, gate)

        try do
          {membership, {retirement, :waiting}} =
            guarded(
              supervisor,
              first,
              gate,
              fn -> remote(first, Fixture, :add_member, [actor, unrelated, team.id], 30_000) end,
              fn ->
                holder = await_gate(gate)

                guarded(
                  supervisor,
                  second,
                  gate,
                  fn -> remote(second, Fixture, :act, [:retire, actor, target], 30_000) end,
                  fn ->
                    _retirement_pid = await_transaction_wait(holder)
                    assert :peer.call(third, Fixture, :snapshot, [actor, target]) == before
                    :waiting
                  end
                )
              end
            )

          assert {:ok, _} = membership
          assert {:ok, _} = retirement
          assert :peer.call(third, Marshall.Teams, :member?, [team.id, unrelated.id])
          refute :peer.call(third, Marshall.Teams, :member?, [team.id, target.id])

          assert %Marshall.Accounts.User{deleted_at: %DateTime{}} =
                   :peer.call(third, Security, :current, [target.id])
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
          Fixture.remove_gate(:team_member, gate)
        end
      after
        Marshall.TeamRetirementFixture.cleanup(team, [])
        Fixture.cleanup([actor, target, unrelated])
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification] admin-account-reversed-participants
  # With actor greater than target, an account mutation MUST wait behind the
  # lower row already held by real sorted consumers. Both callers MUST finish
  # after releasing the independent higher-row blocker; no deadlock is accepted.
  for consumer <- [:guest, :mixed_signout] do
    @consumer consumer
    test "reversed actor/target order agrees with #{@consumer}", %{peers: [first, second, third]} do
      supervisor = start_supervised!(Task.Supervisor)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        [target, actor] =
          Enum.sort_by([Marshall.PasskeyFixture.user(), Marshall.PasskeyFixture.user()], & &1.id)

        actor =
          actor
          |> Marshall.Compute.Ledger.update!(:assign_administrator, %{administrator: true})
          |> Marshall.PasskeyFixture.elevate()

        gate = System.unique_integer([:positive])

        try do
          Fixture.query("SELECT pg_advisory_lock($1)", [gate])

          {holder_result, {consumer_result, {mutation_result, :ordered}}} =
            guarded(
              supervisor,
              first,
              gate,
              fn -> remote(first, Fixture, :hold_user, [actor.id, gate], 30_000) end,
              fn ->
                holder = await_gate(gate)

                guarded(
                  supervisor,
                  second,
                  gate,
                  fn ->
                    remote(second, Fixture, :ordered_consumer, [@consumer, actor, target], 30_000)
                  end,
                  fn ->
                    consumer_pid = await_blocked_by(holder)

                    guarded(
                      supervisor,
                      third,
                      gate,
                      fn -> remote(third, Fixture, :act, [:role, actor, target], 30_000) end,
                      fn ->
                        _mutation_pid = await_transaction_wait(consumer_pid)
                        :ordered
                      end
                    )
                  end
                )
              end
            )

          assert {:ok, :held} = holder_result
          assert {:ok, _} = consumer_result

          if @consumer == :guest do
            assert {:ok, _} = mutation_result
          else
            assert {:error, _} = mutation_result
          end
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
          Fixture.cleanup([actor, target])
        end
      end)
    end
  end

  test "retirement waits for admission fence before taking actor User", %{
    peers: [first, second, third]
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      actor = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      target = Marshall.PasskeyFixture.user()
      gate = System.unique_integer([:positive])

      try do
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])

        {held, {retirement, {lock, :revoked}}} =
          guarded(
            supervisor,
            first,
            gate,
            fn -> remote(first, Fixture, :hold_admission, [target.id, gate], 30_000) end,
            fn ->
              holder = await_gate(gate)

              guarded(
                supervisor,
                second,
                gate,
                fn -> remote(second, Fixture, :act, [:retire, actor, target], 30_000) end,
                fn ->
                  _retirement_pid = await_blocked_by(holder)

                  guarded(
                    supervisor,
                    third,
                    gate,
                    fn -> remote(third, Fixture, :act, [:lock, actor, target], 30_000) end,
                    fn ->
                      await(
                        fn ->
                          if not :peer.call(first, Security, :recent?, [actor]),
                            do: {:ok, :revoked},
                            else: :wait
                        end,
                        "Actor lock waited behind retirement's admission fence"
                      )
                    end
                  )
                end
              )
            end
          )

        assert {:ok, :held} = held
        assert {:ok, _} = lock
        assert {:error, _} = retirement
        assert is_nil(Security.current(target.id).deleted_at)
      after
        Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
        Fixture.cleanup([actor, target])
      end
    end)
  end

  test "failed gate preserves the original assertion and drains mutations before cleanup", %{
    peers: [first, second, third] = peers
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      actor = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      target = Marshall.PasskeyFixture.user()
      gate = System.unique_integer([:positive])

      try do
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])
        Fixture.install_gate(:role, actor, gate)

        try do
          assert_raise ExUnit.AssertionError, ~r/intentional failed-gate cleanup probe/, fn ->
            guarded(
              supervisor,
              first,
              gate,
              fn -> remote(first, Fixture, :act, [:role, actor, target], 30_000) end,
              fn ->
                holder = await_gate(gate)

                guarded(
                  supervisor,
                  second,
                  gate,
                  fn -> remote(second, Fixture, :act, [:lock, actor, target], 30_000) end,
                  fn ->
                    _waiting = await_blocked_by(holder)
                    flunk("intentional failed-gate cleanup probe")
                  end
                )
              end
            )
          end

          before = :peer.call(third, Fixture, :snapshot, [actor, target])
          assert before.user.administrator
          refute :peer.call(third, Security, :recent?, [actor])

          for peer <- peers do
            task =
              Task.Supervisor.async_nolink(supervisor, fn ->
                remote(peer, Fixture, :act, [:reset, actor, target], 30_000)
              end)

            assert {:error, _} = result!(drain(supervisor, peer, task))
            assert :peer.call(peer, Fixture, :snapshot, [actor, target]) == before
          end
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
          Fixture.remove_gate(:role, gate)
        end
      after
        Fixture.cleanup([actor, target])
      end

      assert Fixture.query("SELECT count(*) FROM users WHERE id = ANY($1)", [
               Enum.map([actor.id, target.id], &Ecto.UUID.dump!/1)
             ]).rows == [[0]]

      assert Fixture.query("SELECT count(*) FROM pg_proc WHERE proname=$1", [
               "admin_account_gate_#{gate}"
             ]).rows == [[0]]
    end)
  end

  # pg_blocking_pids includes soft queue edges. Only an actual transaction-ID
  # wait proves this mutation reached the lower row held by the sorted consumer.
  @spec await_transaction_wait(integer()) :: integer()
  defp await_transaction_wait(holder) do
    await(
      fn ->
        case Fixture.query(
               "SELECT waiting.pid FROM pg_locks waiting JOIN pg_locks held USING (transactionid) WHERE waiting.locktype='transactionid' AND NOT waiting.granted AND held.pid=$1 AND held.granted AND held.mode='ExclusiveLock'",
               [holder]
             ).rows do
          [[pid]] -> {:ok, pid}
          [] -> :wait
        end
      end,
      "Mutation did not wait on the lower row owner's transaction"
    )
  end

  @spec await_blocked_by(integer()) :: integer()
  defp await_blocked_by(holder) do
    await(
      fn ->
        Fixture.query("SELECT pg_stat_clear_snapshot()")

        case Fixture.query(
               "SELECT pid FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
               [holder]
             ).rows do
          [[pid]] -> {:ok, pid}
          [] -> :wait
        end
      end,
      "Expected PostgreSQL lock ordering was not observed"
    )
  end

  @spec overlap(
          Fixture.operation(),
          Fixture.operation(),
          :mutation_first | :revocation_first,
          [pid()],
          boolean()
        ) :: :ok
  defp overlap(
         operation,
         competitor,
         order,
         [first, second, third] = peers,
         existing_retirement \\ false
       ) do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      actor = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      target = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user())
      gate = System.unique_integer([:positive])
      leading = if order == :mutation_first, do: operation, else: competitor
      following = if order == :mutation_first, do: competitor, else: operation

      try do
        if existing_retirement, do: assert(match?({:ok, _}, Fixture.act(:retire, actor, target)))
        before = :peer.call(third, Fixture, :snapshot, [actor, target])
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])
        Fixture.install_gate(leading, actor, gate)

        try do
          {one, {two, observed}} =
            guarded(
              supervisor,
              first,
              gate,
              fn -> remote(first, Fixture, :act, [leading, actor, target], 30_000) end,
              fn ->
                holder = await_gate(gate)
                assert :peer.call(third, Fixture, :snapshot, [actor, target]) == before

                guarded(
                  supervisor,
                  second,
                  gate,
                  fn -> remote(second, Fixture, :act, [following, actor, target], 30_000) end,
                  fn -> await_ordering(holder, third, actor, target, before) end
                )
              end
            )

          {mutation, revocation} = if order == :mutation_first, do: {one, two}, else: {two, one}
          assert {:ok, _} = revocation
          assert observed == :blocked

          if order == :mutation_first,
            do: assert(match?({:ok, _}, mutation)),
            else: assert(match?({:error, _}, mutation))

          after_change = :peer.call(third, Fixture, :snapshot, [actor, target])

          expected_kind =
            %{
              role: :grant,
              sessions: :sessions_revoke,
              reset: :mfa_reset,
              retire: :user_delete,
              invite: :user_invite
            }[operation]

          expected_count = if order == :mutation_first or existing_retirement, do: 1, else: 0
          assert Enum.count(after_change.audits, &(&1.kind == expected_kind)) == expected_count

          for peer <- peers do
            assert :peer.call(peer, Fixture, :snapshot, [actor, target]) == after_change

            task =
              Task.Supervisor.async_nolink(supervisor, fn ->
                remote(peer, Fixture, :act, [operation, actor, target], 30_000)
              end)

            assert {:error, _} = result!(drain(supervisor, peer, task))
            assert :peer.call(peer, Fixture, :snapshot, [actor, target]) == after_change
          end

          :ok
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
          Fixture.remove_gate(leading, gate)
        end
      after
        Fixture.cleanup([actor, target])
      end
    end)
  end

  @spec await_ordering(
          integer(),
          pid(),
          Marshall.Accounts.User.t(),
          Marshall.Accounts.User.t(),
          Fixture.snapshot()
        ) :: :blocked | :authority_overtook | :write_overtook
  defp await_ordering(holder, observer, actor, target, before) do
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

          not :peer.call(observer, Security, :recent?, [actor]) ->
            {:ok, :authority_overtook}

          :peer.call(observer, Fixture, :snapshot, [actor, target]) != before ->
            {:ok, :write_overtook}

          true ->
            :wait
        end
      end,
      "Competing operation neither blocked nor committed"
    )
  end

  @typep outcome ::
           {:ok, term()} | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  # @cc [owner:ghuntley,label:verification] admin-account-failed-gate-cleanup
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
