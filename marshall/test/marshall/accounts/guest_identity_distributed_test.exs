defmodule Marshall.Accounts.GuestIdentityDistributedTest do
  use ExUnit.Case, async: false
  require Marshall.CommittedFixtureCleanup, as: Cleanup
  alias Marshall.Accounts.{GuestAccount, User}
  alias Marshall.Compute.Ledger
  alias Marshall.GuestIdentityFixture, as: Fixture
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

  # @cc [owner:ghuntley,label:verification;concurrency] identity-three-independent-marshalls
  # Contention MUST execute production allocation/retirement/roster actions in
  # three independently started BEAMs with separate Repo pools. The coordinating
  # runner is not a peer; the third peer observes committed state before release.
  setup_all do
    peers =
      for number <- 1..3 do
        name = String.to_atom("marshall_guest_identity_#{number}_#{System.pid()}")

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

  test "two callers allocate one fresh account and the third observes its stable commit", %{
    peers: [first, second, third]
  } do
    supervisor = start_supervised!(Task.Supervisor)

    unboxed(fn ->
      user = Marshall.ComputeFixtures.user()

      Cleanup.protect [first, second, third] do
        with_gate(:allocation, user.id, fn gate ->
          before = :peer.call(third, Fixture, :snapshot, [[user.id]])
          assert before.accounts == []

          {left, {right, :ok}} =
            guarded(supervisor, first, gate, fn -> call(first, :allocate, [user.id]) end, fn ->
              holder = await_gate(gate)

              guarded(
                supervisor,
                second,
                gate,
                fn -> call(second, :allocate, [user.id]) end,
                fn ->
                  await_user_wait(holder)
                  assert :peer.call(third, Fixture, :snapshot, [[user.id]]) == before
                  :ok
                end
              )
            end)

          assert {:ok, allocated} = left
          assert {:ok, repeated} = right
          assert allocated.id == repeated.id
          assert {:ok, third_result} = call(third, :allocate, [user.id])
          assert third_result.id == allocated.id
          assert [%{id: id}] = Ledger.read!(GuestAccount, user_id: user.id)
          assert id == allocated.id
        end)
      after
        Fixture.cleanup_users([user])
      end
    end)
  end

  test "different users allocate independent canonical identities while an insertion is blocked",
       %{
         peers: [first, second, third]
       } do
    supervisor = start_supervised!(Task.Supervisor)

    unboxed(fn ->
      old = Marshall.ComputeFixtures.user()
      {:ok, old_account} = Fixture.allocate(old.id)

      Ledger.update!(old, :security_state, %{
        email: "9moved+#{binary_part(Ash.UUID.generate(), 0, 16)}@example.test"
      })

      fresh = Ash.Seed.seed!(User, %{email: to_string(old.email)})
      independent = Marshall.ComputeFixtures.user()

      Cleanup.protect [first, second, third] do
        with_gate(:allocation, fresh.id, fn gate ->
          {left, other} =
            guarded(supervisor, first, gate, fn -> call(first, :allocate, [fresh.id]) end, fn ->
              await_gate(gate)
              assert {:ok, same} = call(second, :allocate, [independent.id])
              assert same.username == "u#{same.uid}"
              assert {:ok, stable} = call(third, :allocate, [old.id])

              assert {stable.id, stable.uid, stable.username} ==
                       {old_account.id, old_account.uid, old_account.username}

              assert call(third, :snapshot, [[fresh.id]]).accounts == []
              same
            end)

          assert {:ok, allocated} = left
          assert allocated.username == "u#{allocated.uid}"
          refute allocated.uid == other.uid
          refute allocated.username == other.username

          assert length(call(third, :snapshot, [[old.id, fresh.id, independent.id]]).accounts) ==
                   3
        end)
      after
        Fixture.cleanup_users([fresh, independent, old])
      end
    end)
  end

  for order <- [:allocation_first, :retirement_first] do
    @order order
    test "allocation and actual retirement preserve identity fences #{@order}", %{
      peers: [first, second, third]
    } do
      supervisor = start_supervised!(Task.Supervisor)

      unboxed(fn ->
        admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
        user = Marshall.ComputeFixtures.user()

        Cleanup.protect [first, second, third] do
          kind = if @order == :allocation_first, do: :allocation, else: :retirement

          with_gate(kind, user.id, fn gate ->
            before = call(third, :snapshot, [[user.id]])
            allocate = fn peer -> call(peer, :allocate, [user.id]) end
            retire = fn peer -> call(peer, :retire, [admin, user]) end

            {leading, following} =
              if @order == :allocation_first, do: {allocate, retire}, else: {retire, allocate}

            {left, {right, :ok}} =
              guarded(supervisor, first, gate, fn -> leading.(first) end, fn ->
                holder = await_gate(gate)

                guarded(supervisor, second, gate, fn -> following.(second) end, fn ->
                  await_user_wait(holder)
                  assert call(third, :snapshot, [[user.id]]) == before
                  :ok
                end)
              end)

            {allocation, retirement} =
              if @order == :allocation_first, do: {left, right}, else: {right, left}

            assert {:ok, %{deleting: true}} = retirement
            final = call(third, :snapshot, [[user.id]])
            assert final.users == [{user.id, true}]

            if @order == :allocation_first do
              assert {:ok, account} = allocation
              assert [{id, owner, name, uid, true}] = final.accounts

              assert {id, owner, name, uid} ==
                       {account.id, user.id, account.username, account.uid}
            else
              assert {:error, :unauthorized} = allocation
              assert final.accounts == []
            end

            assert {:error, :unauthorized} = call(third, :allocate, [user.id])
            assert call(third, :snapshot, [[user.id]]) == final
          end)
        after
          Fixture.cleanup_users([user, admin])
        end
      end)
    end
  end

  test "opposite VM owners acquire overlapping roster users in one canonical order", %{
    peers: [first, second, third]
  } do
    supervisor = start_supervised!(Task.Supervisor)

    unboxed(fn ->
      fixtures = Fixture.roster_fixtures!()
      [low, high] = Enum.sort_by(fixtures, & &1.owner.id)

      Cleanup.protect [first, second, third] do
        Fixture.share!(low, high.owner)
        Fixture.share!(high, low.owner)
        ids = [low.owner.id, high.owner.id]
        gate = System.unique_integer([:positive])
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])

        try do
          before = call(third, :snapshot, [ids])

          {blocked, {left, {right, :ok}}} =
            guarded(
              supervisor,
              third,
              gate,
              fn -> call(third, :hold_user, [high.owner.id, gate]) end,
              fn ->
                holder = await_gate(gate)

                guarded(supervisor, first, gate, fn -> call(first, :roster, [high]) end, fn ->
                  first_waiter = await_user_wait(holder)

                  guarded(supervisor, second, gate, fn -> call(second, :roster, [low]) end, fn ->
                    await_user_wait(first_waiter)
                    assert call(third, :snapshot, [ids]) == before
                    :ok
                  end)
                end)
              end
            )

          assert {:ok, :ok} = blocked
          assert {:ok, %{accounts: left_accounts}} = left
          assert {:ok, %{accounts: right_accounts}} = right
          assert length(left_accounts) == 2
          assert Enum.sort(left_accounts) == Enum.sort(right_accounts)
          assert length(call(third, :snapshot, [ids]).accounts) == 2
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
        end
      after
        Fixture.cleanup_rosters(fixtures)
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
