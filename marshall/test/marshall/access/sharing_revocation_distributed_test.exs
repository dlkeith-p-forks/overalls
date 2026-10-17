defmodule Marshall.Access.SharingRevocationDistributedTest do
  use ExUnit.Case, async: false

  require Marshall.CommittedFixtureCleanup, as: Cleanup

  alias Marshall.Repo
  alias Marshall.SharingRevocationFixture, as: Fixture

  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification] committed-fixture-suite-preservation
  # Every schedule MUST restore its complete pre-test row inventory, including
  # historical rows. ExUnit reports this independent teardown check separately
  # from a body failure; it MUST NOT replace the original assertion.
  setup do
    {before, images_before} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        {Marshall.CommittedFixtureInventory.snapshot(), Cleanup.fixture_image_ids()}
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Cleanup.images!(Cleanup.fixture_image_ids() -- images_before)
        Marshall.CommittedFixtureInventory.assert_restored!(before)
      end)
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification] sharing-revocation-three-peers
  # Every schedule MUST use three distinct BEAM nodes with independent Repo
  # pools and shared committed PostgreSQL; the coordinator is not a peer.
  setup_all do
    peers =
      Enum.map(
        [
          :marshall_sharing_revocation_1,
          :marshall_sharing_revocation_2,
          :marshall_sharing_revocation_3
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

  for surface <- [:ssh, :web], order <- [:renewal_first, :revocation_first] do
    @surface surface
    @order order

    # @cc [owner:ghuntley,label:verification;concurrency;security] sharing-revoke-renewal-serialization
    # A committed renewal and a committed revocation MUST serialize on the VM
    # row in both commit orders: each waiting side MUST be observed blocked on
    # the leader's transaction. A renewal committed before the revocation may
    # extend its lease by at most the five-second TTL; after a committed
    # revocation no renewal may extend or revive a still-live lease, on any
    # peer. Denial while the lease is unexpired proves authority decided.
    test "#{@surface} renewal versus revocation serializes on the VM row, #{@order}",
         %{peers: [first, second, third] = peers} do
      supervisor = start_supervised!(Task.Supervisor)

      unboxed(fn ->
        context = Fixture.setup()
        assert {:ok, _} = Fixture.renew(context, @surface)

        Cleanup.protect [first, second, third] do
          before = :peer.call(third, Fixture, :snapshot, [context])
          lease_before = Fixture.expires_at(context, @surface)
          gate = System.unique_integer([:positive])
          Fixture.query("SELECT pg_advisory_lock($1)", [gate])

          try do
            case @order do
              :renewal_first ->
                Fixture.install_gate(:renewal, context, gate)

                {renewal, {revoke, :blocked}} =
                  guarded(
                    supervisor,
                    first,
                    gate,
                    fn -> remote(first, Fixture, :renew, [context, @surface], 30_000) end,
                    fn ->
                      holder = await_gate(gate)
                      assert :peer.call(third, Fixture, :snapshot, [context]) == before

                      guarded(
                        supervisor,
                        second,
                        gate,
                        fn -> remote(second, Fixture, :revoke, [context], 30_000) end,
                        fn ->
                          _waiting = await_blocked_by(holder)
                          :blocked
                        end
                      )
                    end
                  )

                assert {:ok, renewed} = renewal
                assert renewed.binding.session_id == lease_id(context, @surface)
                assert {:ok, _} = revoke

                # The committed renewal extended the same lease, never beyond
                # the five-second TTL measured on the database clock.
                assert Fixture.extended?(context, @surface, lease_before)
                assert Fixture.within_ttl?(context, @surface)

              :revocation_first ->
                Fixture.install_gate(:revoke, context, gate)

                {revoke, {renewal, :blocked}} =
                  guarded(
                    supervisor,
                    first,
                    gate,
                    fn -> remote(first, Fixture, :revoke, [context], 30_000) end,
                    fn ->
                      holder = await_gate(gate)
                      assert :peer.call(third, Fixture, :snapshot, [context]) == before

                      guarded(
                        supervisor,
                        second,
                        gate,
                        fn -> remote(second, Fixture, :renew, [context, @surface], 30_000) end,
                        fn ->
                          _waiting = await_blocked_by(holder)
                          :blocked
                        end
                      )
                    end
                  )

                assert {:ok, _} = revoke
                assert {:error, _} = renewal

                # The gated revocation committed first: the waiting renewal met
                # revoked authority, and the lease expiry never moved.
                assert Fixture.expires_at(context, @surface) == lease_before
                refute Fixture.extended?(context, @surface, lease_before)
            end

            after_revoke = :peer.call(third, Fixture, :snapshot, [context])
            refute after_revoke.grant_active
            assert after_revoke.changes == before.changes + 1

            # Every later denial is authority proof: the lease is still live on
            # the database clock, so expiry cannot explain refusal.
            assert Fixture.live?(context, @surface)

            for peer <- peers do
              task =
                Task.Supervisor.async_nolink(supervisor, fn ->
                  remote(peer, Fixture, :renew, [context, @surface], 30_000)
                end)

              assert {:error, _} = result!(drain(supervisor, peer, task))

              task =
                Task.Supervisor.async_nolink(supervisor, fn ->
                  remote(peer, Fixture, :open_again, [context, @surface], 30_000)
                end)

              assert {:error, _} = result!(drain(supervisor, peer, task))
            end

            # Failed renewals never touched either lease.
            assert :peer.call(third, Fixture, :snapshot, [context]) == after_revoke
          after
            Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
            Fixture.remove_gates(:renewal, context)
            Fixture.remove_gates(:revoke, context)
          end
        after
          Fixture.cleanup(context)
        end
      end)
    end
  end

  # @cc [owner:ghuntley,label:verification;concurrency;security] sharing-revoke-both-surfaces-chain
  # One committed revocation MUST fence queued renewals on both surfaces at
  # once: the first renewal waits on the revocation's VM row and (because a web
  # renewal takes the gateway row FOR UPDATE while SSH takes it FOR SHARE) the
  # second renewal chains behind the first. After the single revocation commits,
  # both live leases are denied by authority — expiry never moves.
  test "one revocation fences queued SSH and web renewals on three peers",
       %{peers: [first, second, third] = peers} do
    supervisor = start_supervised!(Task.Supervisor)

    unboxed(fn ->
      context = Fixture.setup()
      assert {:ok, _} = Fixture.renew(context, :ssh)
      assert {:ok, _} = Fixture.renew(context, :web)

      Cleanup.protect [first, second, third] do
        ssh_before = Fixture.expires_at(context, :ssh)
        web_before = Fixture.expires_at(context, :web)
        gate = System.unique_integer([:positive])
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])
        Fixture.install_gate(:revoke, context, gate)

        try do
          revoke_task =
            Task.Supervisor.async_nolink(supervisor, fn ->
              remote(first, Fixture, :revoke, [context], 30_000)
            end)

          holder = await_gate(gate)
          assert :peer.call(third, Fixture, :snapshot, [context]).grant_active

          ssh_task =
            Task.Supervisor.async_nolink(supervisor, fn ->
              remote(second, Fixture, :renew, [context, :ssh], 30_000)
            end)

          web_task =
            Task.Supervisor.async_nolink(supervisor, fn ->
              remote(third, Fixture, :renew, [context, :web], 30_000)
            end)

          # The first renewal to reach the VM row waits on the revocation; the
          # second chains behind it through the shared gateway row.
          leading = await_blocked_by(holder)
          _trailing = await_blocked_by(leading)
          assert direct_waiter_count(holder) == 1

          # Release the committed revocation; both queued renewals must observe
          # revoked authority behind it.
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])

          assert {:ok, _} = result!(drain(supervisor, first, revoke_task))
          assert {:error, _} = result!(drain(supervisor, second, ssh_task))
          assert {:error, _} = result!(drain(supervisor, third, web_task))

          after_revoke = :peer.call(third, Fixture, :snapshot, [context])
          refute after_revoke.grant_active
          assert Fixture.live?(context, :ssh)
          assert Fixture.live?(context, :web)
          assert Fixture.expires_at(context, :ssh) == ssh_before
          assert Fixture.expires_at(context, :web) == web_before

          for peer <- peers, surface <- [:ssh, :web] do
            task =
              Task.Supervisor.async_nolink(supervisor, fn ->
                remote(peer, Fixture, :renew, [context, surface], 30_000)
              end)

            assert {:error, _} = result!(drain(supervisor, peer, task))
          end

          assert :peer.call(third, Fixture, :snapshot, [context]) == after_revoke
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
          Fixture.remove_gates(:renewal, context)
          Fixture.remove_gates(:revoke, context)
        end
      after
        Fixture.cleanup(context)
      end
    end)
  end

  @spec lease_id(Fixture.context(), Fixture.surface()) :: String.t()
  defp lease_id(context, :ssh), do: context.ssh_session_id
  defp lease_id(context, :web), do: context.web_stream_id

  @spec unboxed((-> result)) :: result when result: term()
  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  @spec remote(pid(), module(), atom(), [term()], pos_integer()) ::
          {:completed, Fixture.outcome()}
  defp remote(peer, module, function, arguments, timeout),
    do: :peer.call(peer, Fixture, :invoke, [module, function, arguments], timeout)

  # @cc [owner:ghuntley,label:verification] sharing-revoke-failed-gate-cleanup
  # Any failed assertion MUST release the advisory gate and drain the remote
  # operation before fixture cleanup; an unsure remote outcome MUST stop its
  # peer. The original assertion MUST remain the reported failure.
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

  @spec direct_waiter_count(integer()) :: non_neg_integer()
  defp direct_waiter_count(holder) do
    Fixture.query("SELECT pg_stat_clear_snapshot()")

    [[count]] =
      Fixture.query(
        "SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
        [holder]
      ).rows

    count
  end

  @spec await((-> {:ok, value} | :wait), String.t(), non_neg_integer()) :: value
        when value: term()
  defp await(probe, message, attempts \\ 400)
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
