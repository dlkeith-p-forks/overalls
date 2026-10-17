defmodule Marshall.SSH.GuestRosterDistributedTest do
  use ExUnit.Case, async: false
  require Marshall.CommittedFixtureCleanup, as: Cleanup
  alias Marshall.Accounts.GuestAccount
  alias Marshall.Compute.Ledger
  alias Marshall.GuestIdentityFixture, as: Fixture
  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification] roster-fixture-suite-preservation
  # Every schedule MUST restore its complete pre-test committed row inventory,
  # including historical rows. ExUnit reports this independent teardown check
  # separately from a body failure; it MUST NOT replace the original assertion.
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

  # @cc [owner:ghuntley,label:verification;concurrency] roster-three-independent-marshalls
  # Contention MUST execute production retirement/roster actions in three
  # independently started BEAMs with separate Repo pools sharing PostgreSQL.
  # The coordinating runner is not a peer; the third peer observes committed
  # state before controlled gate release.
  setup_all do
    peers =
      for number <- 1..3 do
        name = String.to_atom("marshall_roster_identity_#{number}_#{System.pid()}")

        peer =
          start_supervised!(%{
            id: name,
            restart: :temporary,
            start:
              {:peer, :start_link,
               [
                 %{
                   name: name,
                   connection: :standard_io,
                   args: [~c"+S", ~c"2:2", ~c"+SDcpu", ~c"1", ~c"+SDio", ~c"1"],
                   wait_boot: 30_000
                 }
               ]}
          })

        :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])

        config =
          for {app, _, _} <- Application.loaded_applications(),
              app not in [:kernel, :stdlib, :elixir, :logger],
              do: {app, Application.get_all_env(app)}

        :ok = :peer.call(peer, Application, :put_all_env, [config, [persistent: true]])

        repo =
          Application.fetch_env!(:marshall, Repo)
          |> Keyword.put(:pool, DBConnection.ConnectionPool)
          |> Keyword.put(:pool_size, 4)

        :ok = :peer.call(peer, Application, :put_env, [:marshall, Repo, repo, [persistent: true]])

        :ok =
          :peer.call(peer, Application, :put_env, [:logger, :level, :error, [persistent: true]])

        {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:marshall], 30_000)
        peer
      end

    nodes = Enum.map(peers, &:peer.call(&1, :erlang, :node, []))
    assert length(Enum.uniq(nodes)) == 3
    refute node() in nodes
    %{peers: peers}
  end

  # @cc [owner:ghuntley,label:verification;concurrency] roster-contested-retirement-recheck
  # A roster fetch contested by a concurrently committing retirement MUST
  # recheck the locked User row and refuse atomically: no fresh allocation for
  # the retired candidate, every durable name/UID untouched, and the next clean
  # fetch MUST serve exactly the surviving preserved identities.
  test "a roster fetch refuses a concurrently retired candidate atomically and preserves survivors",
       %{peers: [first, second, third]} do
    supervisor = start_supervised!(Task.Supervisor)

    unboxed(fn ->
      fixtures = Fixture.roster_fixtures!()
      fixture = hd(fixtures)
      grantee = Marshall.ComputeFixtures.user()
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))

      Cleanup.protect [first, second, third] do
        Fixture.share!(fixture, grantee)

        assert {:ok, %{version: base_version, accounts: base}} = Fixture.roster(fixture)
        assert length(base) == 2

        with_gate(:retirement, grantee.id, fn gate ->
          before = call(third, :snapshot, [[grantee.id, fixture.owner.id]])

          assert Enum.sort(before.users) ==
                   Enum.sort([{grantee.id, false}, {fixture.owner.id, false}])

          assert length(before.accounts) == 2

          {retirement, {roster_result, :ok}} =
            guarded(
              supervisor,
              first,
              gate,
              fn -> call(first, :retire, [admin, grantee]) end,
              fn ->
                holder = await_gate(gate)

                guarded(
                  supervisor,
                  second,
                  gate,
                  fn -> call(second, :roster, [fixture]) end,
                  fn ->
                    await_user_wait(holder)
                    assert call(third, :snapshot, [[grantee.id, fixture.owner.id]]) == before
                    :ok
                  end
                )
              end
            )

          assert {:ok, %{deleting: true}} = retirement
          assert {:error, :unauthorized} = roster_result

          final = call(third, :snapshot, [[grantee.id, fixture.owner.id]])
          assert final.users == Enum.sort([{grantee.id, true}, {fixture.owner.id, false}])

          assert Enum.map(final.accounts, &Tuple.delete_at(&1, 4)) ==
                   Enum.map(before.accounts, &Tuple.delete_at(&1, 4))

          assert Enum.any?(final.accounts, &(elem(&1, 1) == grantee.id and elem(&1, 4)))
        end)

        [owner_row] = Ledger.read!(GuestAccount, user_id: fixture.owner.id)

        assert {:ok, %{version: recovered_version, accounts: recovered}} =
                 Fixture.roster(fixture)

        assert recovered_version > base_version
        assert recovered == [%{username: owner_row.username, uid: owner_row.uid}]
      after
        Fixture.cleanup_rosters(fixtures)
        Fixture.cleanup_users([grantee, admin])
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification;concurrency] roster-duplicate-fetch-serialization
  # Concurrent roster fetches for one VM MUST serialize through the locked VM
  # row before user/namespace locks, agree on one durable identity set with
  # distinct fresh versions, and leave no uncommitted observation visible to a
  # third peer.
  test "two concurrent roster fetches commit the same durable identities with fresh versions",
       %{peers: [first, second, third]} do
    supervisor = start_supervised!(Task.Supervisor)

    unboxed(fn ->
      fixtures = Fixture.roster_fixtures!()
      fixture = hd(fixtures)
      grantee = Marshall.ComputeFixtures.user()

      Cleanup.protect [first, second, third] do
        Fixture.share!(fixture, grantee)
        gated = [fixture.owner.id, grantee.id] |> Enum.sort() |> List.last()

        with_gate(:allocation, gated, fn gate ->
          before = call(third, :snapshot, [[fixture.owner.id, grantee.id]])
          assert before.accounts == []

          {left, {right, :ok}} =
            guarded(supervisor, first, gate, fn -> call(first, :roster, [fixture]) end, fn ->
              holder = await_gate(gate)

              guarded(supervisor, second, gate, fn -> call(second, :roster, [fixture]) end, fn ->
                await_vm_wait(holder)
                assert call(third, :snapshot, [[fixture.owner.id, grantee.id]]) == before
                :ok
              end)
            end)

          assert {:ok, %{version: v1, accounts: accounts1}} = left
          assert {:ok, %{version: v2, accounts: accounts2}} = right
          assert accounts1 == accounts2
          assert length(accounts1) == 2
          assert v1 != v2

          final = call(third, :snapshot, [[fixture.owner.id, grantee.id]])
          assert length(final.accounts) == 2

          returned =
            final.accounts
            |> Enum.map(fn {_id, _owner, name, uid, _retired} -> %{username: name, uid: uid} end)
            |> Enum.sort()

          assert returned == Enum.sort(accounts1)
          refute Enum.any?(final.accounts, &elem(&1, 4))
        end)
      after
        Fixture.cleanup_rosters(fixtures)
        Fixture.cleanup_users([grantee])
      end
    end)
  end

  @spec call(pid(), atom(), [term()]) :: term()
  defp call(peer, operation, args), do: :peer.call(peer, Fixture, operation, args, 30_000)

  @spec unboxed((-> result)) :: result when result: term()
  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  @spec with_gate(Fixture.gate_kind(), String.t(), (pos_integer() -> result)) :: result
        when result: term()
  defp with_gate(kind, target, body) do
    gate = System.unique_integer([:positive])
    Fixture.query("SELECT pg_advisory_lock($1)", [gate])
    Fixture.install_gate(kind, target, gate)

    try do
      body.(gate)
    after
      Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
      Fixture.remove_gate(kind, target)
    end
  end

  @typep outcome ::
           {:ok, term()} | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}
  # @cc [owner:ghuntley,label:verification] guest-identity-failed-schedule-cleanup
  # Assertion failures MUST release barriers and drain their own callers before
  # deleting fixture state. Unresponsive peers MUST stop before cleanup, and the
  # original assertion MUST remain the test's reported failure.
  @spec guarded(pid(), pid(), pos_integer(), (-> term()), (-> result)) :: {term(), result}
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
      {^receipt, task_result} ->
        value = result!(result)
        {result!(task_result), value}
    end
  end

  @spec drain(pid(), pid(), Task.t()) :: outcome()
  defp drain(supervisor, peer, task) do
    try do
      {:ok, Task.await(task, 35_000)}
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        Task.Supervisor.terminate_child(supervisor, task.pid)
        :peer.stop(peer)
        {:raised, kind, reason, stacktrace}
    end
  end

  @spec result!(outcome()) :: term()
  defp result!({:ok, value}), do: value
  defp result!({:raised, kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)

  @spec await_gate(pos_integer()) :: pos_integer()
  defp await_gate(gate),
    do:
      await(
        fn ->
          case Fixture.query(
                 "SELECT pid FROM pg_locks WHERE locktype='advisory' AND objid=$1 AND NOT granted",
                 [gate]
               ).rows do
            [[pid]] -> {:ok, pid}
            _ -> :wait
          end
        end,
        "Production call did not reach its target write gate"
      )

  @spec await_user_wait(pos_integer()) :: pos_integer()
  defp await_user_wait(holder),
    do:
      await(
        fn ->
          case Fixture.query(
                 "SELECT pid FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid)) AND query LIKE '%FROM \"users\"%' AND query LIKE '%FOR UPDATE%'",
                 [holder]
               ).rows do
            [[pid]] -> {:ok, pid}
            _ -> :wait
          end
        end,
        "Production call did not wait on the expected User row owner"
      )

  @spec await_vm_wait(pos_integer()) :: pos_integer()
  defp await_vm_wait(holder),
    do:
      await(
        fn ->
          case Fixture.query(
                 "SELECT pid FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid)) AND query LIKE '%FROM \"compute_virtual_machines\"%' AND query LIKE '%FOR UPDATE%'",
                 [holder]
               ).rows do
            [[pid]] -> {:ok, pid}
            _ -> :wait
          end
        end,
        "Production roster did not wait on the expected VirtualMachine row owner"
      )

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
