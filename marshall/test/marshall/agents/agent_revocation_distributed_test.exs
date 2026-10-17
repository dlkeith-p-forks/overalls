defmodule Marshall.Agents.AgentRevocationDistributedTest do
  use ExUnit.Case, async: false

  alias Marshall.AgentRevocationFixture, as: Fixture
  alias Marshall.Agents.{CLIAccess, Command, ExecutorSession, Loop}
  alias Marshall.Agents.ModelCalls
  alias Marshall.Compute.Ledger
  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification] agent-revocation-three-independent-peers
  # Every schedule MUST use three distinct Marshall BEAMs and Repo pools; the
  # coordinator MUST NOT count as one of those instances.
  setup_all do
    # Separate BEAMs, Repo pools and Cedar handles share only PostgreSQL. The
    # parent test node is not counted among the three control-plane instances.
    peers =
      Enum.map(
        [
          :marshall_agent_revocation_1,
          :marshall_agent_revocation_2,
          :marshall_agent_revocation_3
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

  for leader <- [:first, :second] do
    @leader leader
    test "concurrent same-digest approvals admit exactly one session with #{@leader} leading",
         %{peers: peers} do
      concurrent_approvals(peers, @leader)
    end
  end

  for order <- [:claim_first, :withdrawal_first] do
    @order order
    test "tool claim and access withdrawal serialize #{@order}", %{peers: peers} do
      claim_withdrawal(peers, @order)
    end
  end

  test "a loop pass mid-withdrawal preserves pre-commit authority and settles after commit",
       %{peers: peers} do
    loop_during_withdrawal(peers)
  end

  test "registration completes when it reads authority ahead of owner retirement",
       %{peers: peers} do
    register_during_retire(peers)
  end

  test "registration refuses a retired owner from every peer", %{peers: peers} do
    register_after_retire(peers)
  end

  @spec concurrent_approvals([pid()], :first | :second) :: :ok
  defp concurrent_approvals([first, second, third] = peers, leader) do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      c = Fixture.setup()
      secret = "overalls_agent_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      code = Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
      gate = System.unique_integer([:positive])

      [leader_peer, follower_peer] =
        if leader == :first, do: [first, second], else: [second, first]

      try do
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])
        Fixture.install_gate(:approve, %{code: code}, gate)

        try do
          {one, {two, :blocked}} =
            guarded(
              supervisor,
              leader_peer,
              gate,
              fn ->
                remote(leader_peer, CLIAccess, :approve, [c.vm.id, code, c.member], 30_000)
              end,
              fn ->
                holder = await_gate(gate)

                # The leader holds the VM/approval write; no committed session
                # is visible to an independent peer yet.
                assert [] ==
                         Fixture.query(
                           "SELECT id FROM agent_cli_sessions WHERE code_hash='#{code}'",
                           []
                         ).rows

                guarded(
                  supervisor,
                  follower_peer,
                  gate,
                  fn ->
                    remote(follower_peer, CLIAccess, :approve, [c.vm.id, code, c.member], 30_000)
                  end,
                  fn -> :blocked = await_blocked_by(holder) end
                )
              end
            )

          results = [one, two]
          assert Enum.count(results, &match?({:ok, _}, &1)) == 1
          assert Enum.count(results, &match?({:error, _}, &1)) == 1

          assert [[1]] ==
                   Fixture.query(
                     "SELECT count(*) FROM agent_cli_sessions WHERE code_hash='#{code}'",
                     []
                   ).rows

          kinds =
            Fixture.query(
              "SELECT kind::text, count(*) FROM agent_audit_events WHERE vm_id='#{c.vm.id}' AND kind IN ('cli_approved','cli_refused') GROUP BY kind ORDER BY kind",
              []
            ).rows
            |> Map.new(fn [kind, count] -> {kind, count} end)

          assert kinds["cli_approved"] == 2
          assert kinds["cli_refused"] == 1

          final_initial = :peer.call(third, Fixture, :snapshot, [c.vm.id])

          # Every further approval of the committed digest is a clean closed
          # refusal from each peer, never a crash or a second session.
          for peer <- peers do
            task =
              Task.Supervisor.async_nolink(supervisor, fn ->
                remote(peer, CLIAccess, :approve, [c.vm.id, code, c.member], 30_000)
              end)

            assert {:error, _} = result!(drain(supervisor, peer, task))
          end

          assert [[4]] ==
                   Fixture.query(
                     "SELECT count(*) FROM agent_audit_events WHERE vm_id='#{c.vm.id}' AND kind='cli_refused'",
                     []
                   ).rows

          assert [[1]] ==
                   Fixture.query(
                     "SELECT count(*) FROM agent_cli_sessions WHERE code_hash='#{code}'",
                     []
                   ).rows

          refute :peer.call(third, Fixture, :snapshot, [c.vm.id]) == final_initial

          final = :peer.call(third, Fixture, :snapshot, [c.vm.id])

          for peer <- peers do
            assert :peer.call(peer, Fixture, :snapshot, [c.vm.id]) == final
          end

          :ok
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
          Fixture.remove_gate(gate)
        end
      after
        Fixture.cleanup(c)
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification] agent-claim-withdrawal-scoped-fixture
  # Claim/withdrawal schedules MUST select the queued effect command without
  # treating completed context commands as effects, and MUST clean their
  # committed fixture even if preparation fails before the concurrency gate.
  @spec claim_withdrawal([pid()], :claim_first | :withdrawal_first) :: :ok
  defp claim_withdrawal([first, second, third] = peers, order) do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      c = Fixture.setup()

      try do
        turn = Fixture.submit!(c)
        assert :ok = Fixture.tick()
        assert %{status: :running} = Fixture.turn(turn.id)
        Fixture.queue_tool!(c, turn)
        executor = Fixture.register!(c)

        [command] =
          Ledger.read!(Command, turn_id: turn.id, call_id: "effect", tool: :exec_command)

        gate = System.unique_integer([:positive])
        leading = if order == :claim_first, do: :claim, else: :withdraw

        operation = fn
          :claim, peer ->
            remote(
              peer,
              ExecutorSession,
              :claim,
              [c.binding, executor.id, executor.fence_epoch],
              30_000
            )

          :withdraw, peer ->
            remote(peer, Fixture, :share, [c, :revoked], 30_000)
        end

        follower = if order == :claim_first, do: :withdraw, else: :claim
        before = :peer.call(third, Fixture, :snapshot, [c.vm.id])
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])

        keys =
          case leading do
            :claim -> %{command_id: command.id}
            :withdraw -> %{member_id: c.member.id}
          end

        Fixture.install_gate(leading, keys, gate)

        try do
          {one, {two, :blocked}} =
            guarded(
              supervisor,
              first,
              gate,
              fn -> operation.(leading, first) end,
              fn ->
                holder = await_gate(gate)

                # The gated leader has not committed; an independent peer still
                # observes the pre-schedule rows.
                assert :peer.call(third, Fixture, :snapshot, [c.vm.id]) == before

                guarded(
                  supervisor,
                  second,
                  gate,
                  fn -> operation.(follower, second) end,
                  fn -> :blocked = await_blocked_by(holder) end
                )
              end
            )

          {claim, withdraw} =
            if order == :claim_first, do: {one, two}, else: {two, one}

          assert {:ok, _} = withdraw

          case order do
            :claim_first ->
              assert {:ok, %{id: claimed_id}} = claim
              assert claimed_id == command.id
              assert [%{status: :claimed}] = Ledger.read!(Command, id: command.id)

            :withdrawal_first ->
              assert {:error, :access_revoked} = claim
              assert [%{status: :queued}] = Ledger.read!(Command, id: command.id)
          end

          # Settle: the running turn must fail with :access_revoked on the next
          # loop pass, and the in-flight or orphaned command retires exactly
          # once.
          assert :ok = Fixture.tick()
          assert :ok = Fixture.tick()

          assert %{status: :failed, failure_reason: :access_revoked} = Fixture.turn(turn.id)

          assert [[1]] ==
                   Fixture.query(
                     "SELECT count(*) FROM agent_events WHERE turn_id=$1 AND kind IN ('turn_failed','assistant')",
                     [Ecto.UUID.dump!(turn.id)]
                   ).rows

          case order do
            :claim_first ->
              replacement = Fixture.register!(c)

              assert {:ok, nil} =
                       ExecutorSession.claim(c.binding, replacement.id, replacement.fence_epoch)

              assert [%{status: :cancelled}] = Ledger.read!(Command, id: command.id)

            :withdrawal_first ->
              assert :ok = Fixture.tick()

              assert [%{status: :cancelled, result: %{"reason" => "turn_finished"}}] =
                       Ledger.read!(Command, id: command.id)
          end

          # CLI authority is closed on every peer; no new model claims appear.
          assert {:error, :unauthorized} =
                   :peer.call(third, CLIAccess, :authorize, [c.vm.id, c.secret])

          assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)

          final = :peer.call(third, Fixture, :snapshot, [c.vm.id])
          :ok = Fixture.tick()
          assert :peer.call(third, Fixture, :snapshot, [c.vm.id]) == final

          for peer <- peers, do: assert(:peer.call(peer, Fixture, :snapshot, [c.vm.id]) == final)

          :ok
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
          Fixture.remove_gate(gate)
        end
      after
        Fixture.cleanup(c)
      end
    end)
  end

  @spec loop_during_withdrawal([pid()]) :: :ok
  defp loop_during_withdrawal([first, second, third]) do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      c = Fixture.setup()
      turn = Fixture.submit!(c)
      gate = System.unique_integer([:positive])

      try do
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])
        Fixture.install_gate(:withdraw, %{member_id: c.member.id}, gate)

        try do
          {withdraw, {tick_result, :running}} =
            guarded(
              supervisor,
              first,
              gate,
              fn -> remote(first, Fixture, :share, [c, :revoked], 30_000) end,
              fn ->
                _holder = await_gate(gate)

                # The loop pass on an independent peer mid-withdrawal observes
                # only committed authority: the queued turn claims and starts
                # honestly before the withdrawal commits anything.
                guarded(
                  supervisor,
                  second,
                  gate,
                  fn -> remote(second, Loop, :tick, [], 30_000) end,
                  fn ->
                    await(
                      fn ->
                        case Fixture.turn(turn.id).status do
                          :running -> {:ok, :running}
                          _ -> :wait
                        end
                      end,
                      "Tick did not claim the queued turn while withdrawal was in flight"
                    )
                  end
                )
              end
            )

          assert {:ok, _} = withdraw
          assert :ok = tick_result

          # The committed withdrawal takes effect on the next loop pass: the
          # running turn fails with :access_revoked exactly once.
          assert :ok = Fixture.tick()
          assert :ok = Fixture.tick()

          assert %{status: :failed, failure_reason: :access_revoked} = Fixture.turn(turn.id)

          assert [[1]] ==
                   Fixture.query(
                     "SELECT count(*) FROM agent_events WHERE turn_id=$1 AND kind IN ('turn_failed','assistant')",
                     [Ecto.UUID.dump!(turn.id)]
                   ).rows

          final = :peer.call(third, Fixture, :snapshot, [c.vm.id])
          assert :ok = Fixture.tick()
          assert :peer.call(third, Fixture, :snapshot, [c.vm.id]) == final
          :ok
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
          Fixture.remove_gate(gate)
        end
      after
        Fixture.cleanup(c)
      end
    end)
  end

  @spec register_during_retire([pid()]) :: :ok
  defp register_during_retire([first, second, _third]) do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      c = Fixture.setup()
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      gate = System.unique_integer([:positive])

      try do
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])
        Fixture.install_gate(:register, %{vm_id: c.vm.id}, gate)

        try do
          {register, {retire, :raced}} =
            guarded(
              supervisor,
              first,
              gate,
              fn -> remote(first, ExecutorSession, :register, [c.binding, nil], 30_000) end,
              fn ->
                _holder = await_gate(gate)

                # The register transaction is suspended at its own write and
                # has committed nothing yet to an independent observer.
                assert [] == Ledger.read!(Marshall.Agents.Executor, vm_id: c.vm.id)

                guarded(
                  supervisor,
                  second,
                  gate,
                  fn -> remote(second, Fixture, :retire_owner, [admin, c.owner], 30_000) end,
                  fn ->
                    # Retirement runs on a disjoint authority path (user rows,
                    # not this VM row); it may complete while the register
                    # transaction is suspended at its write gate.
                    Fixture.query("SELECT pg_stat_clear_snapshot()")
                    :raced
                  end
                )
              end
            )

          assert {:ok, %{id: _}} = register
          assert {:ok, %{deleting: true}} = retire

          # Retirement committed after the authority read: the next
          # registration from any peer must close with :access_revoked.
          assert [[1]] ==
                   Fixture.query(
                     "SELECT count(*) FROM agent_executors WHERE vm_id='#{c.vm.id}'",
                     []
                   ).rows

          assert {:error, :access_revoked} = ExecutorSession.register(c.binding)
          assert {:error, :access_revoked} = ExecutorSession.register(c.binding)
          :ok
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
          Fixture.remove_gate(gate)
        end
      after
        Fixture.cleanup(c, [admin])
      end
    end)
  end

  @spec register_after_retire([pid()]) :: :ok
  defp register_after_retire(peers) do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      c = Fixture.setup()
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))

      try do
        assert {:ok, %{deleting: true}} = Fixture.retire_owner(admin, c.owner)

        for peer <- peers do
          task =
            Task.Supervisor.async_nolink(supervisor, fn ->
              remote(peer, ExecutorSession, :register, [c.binding, nil], 30_000)
            end)

          assert {:error, :access_revoked} = result!(drain(supervisor, peer, task))
        end

        assert [] = Ledger.read!(Marshall.Agents.Executor, vm_id: c.vm.id)
        assert {:error, :unauthorized} = CLIAccess.authorize(c.vm.id, c.secret)
        :ok
      after
        Fixture.cleanup(c, [admin])
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification] agent-revocation-failed-gate-cleanup
  # Any failed assertion MUST release the gate and drain both production calls
  # before fixture deletion; the original assertion remains the reported failure.
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

  @spec drain(pid(), pid(), Task.t()) :: Fixture.outcome()
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

  @spec result!(Fixture.outcome()) :: term()
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

  @spec await_blocked_by(integer()) :: :blocked
  defp await_blocked_by(holder) do
    await(
      fn ->
        Fixture.query("SELECT pg_stat_clear_snapshot()")

        case Fixture.query(
               "SELECT pid FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
               [holder]
             ).rows do
          [[_pid]] -> {:ok, :blocked}
          [] -> :wait
        end
      end,
      "Expected PostgreSQL lock ordering was not observed"
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
        Process.sleep(100)
        await(probe, message, attempts - 1)
    end
  end
end
