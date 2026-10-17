defmodule Marshall.SSH.CredentialRetirementDistributedTest do
  use ExUnit.Case, async: false
  alias Marshall.CommittedFixtureCleanup, as: Cleanup
  require Cleanup
  alias Marshall.Accounts.Security
  alias Marshall.Compute.Ledger
  alias Marshall.Repo
  alias Marshall.CredentialRetirementFixture, as: Fixture
  alias Marshall.SSH

  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification] credential-three-independent-peers
  # All schedules MUST use three distinct BEAM nodes with independent Repo pools;
  # the coordinating node MUST NOT count as one of the three instances.
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
          :marshall_credential_retirement_1,
          :marshall_credential_retirement_2,
          :marshall_credential_retirement_3
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

  for operation <- [:manual, :approval], order <- [:registration_first, :retirement_first] do
    @operation operation
    @order order
    test "#{operation} registration and cleanup serialize #{order}", %{peers: peers} do
      overlap(@operation, @order, peers)
    end
  end

  # @cc [owner:ghuntley,label:verification] credential-retirement-durable-oracle
  # The tests MUST pause actual production writes, observe completed cleanup on
  # a separate peer, and verify exact key/approval/audit history. Refused calls
  # MUST add no records; cleanup MUST release the fingerprint for a fresh account.
  @spec overlap(Fixture.operation(), :registration_first | :retirement_first, [pid()]) :: :ok
  defp overlap(operation, order, [first, second, third] = peers) do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      account = Marshall.PasskeyFixture.user()
      fixture = Fixture.registration()
      fresh = Marshall.PasskeyFixture.user()

      Cleanup.protect peers do
        before = :peer.call(third, Fixture, :snapshot, [account.id, fixture])
        gate = System.unique_integer([:positive])
        kind = if order == :registration_first, do: :registration, else: :retirement
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])
        Fixture.install_gate(kind, account.id, gate)

        Cleanup.protect do
          register = fn peer ->
            :peer.call(peer, Fixture, :register, [operation, fixture, account], 30_000)
          end

          retire = fn peer ->
            :peer.call(peer, Fixture, :retire_and_complete, [admin, account], 30_000)
          end

          {leading, following} =
            if order == :registration_first, do: {register, retire}, else: {retire, register}

          {first_result, {second_result, observation}} =
            guarded(supervisor, first, gate, fn -> leading.(first) end, fn ->
              holder = await_gate(gate)
              assert :peer.call(third, Fixture, :snapshot, [account.id, fixture]) == before

              guarded(supervisor, second, gate, fn -> following.(second) end, fn ->
                await_ordering(holder, account.id, order, third, fixture, before)
              end)
            end)

          {registration, retirement} =
            if order == :registration_first,
              do: {first_result, second_result},
              else: {second_result, first_result}

          assert {:ok, %{id: deletion_id}} = retirement
          final = :peer.call(third, Fixture, :snapshot, [account.id, fixture])
          assert final.retired
          assert final.deletions == [{deletion_id, true, 0, false}]
          assert final.events == [{admin.id, account.id, :user_delete}]
          assert [] == Ledger.read!(SSH.Key, user_id: account.id)
          assert observation == :account_fence

          if order == :registration_first do
            assert {:ok, _} = registration
            assert [{key_id, owner, true}] = final.keys
            assert owner == account.id

            assert final.versions ==
                     Enum.sort([
                       {key_id, :register, :user, account.id},
                       {key_id, :revoke, :system, nil}
                     ])

            if operation == :approval do
              assert [{approval_id, owner, true}] = final.approvals
              assert owner == account.id
              assert [{^approval_id, nil, false}] = before.approvals
              assert final.sessions == [{fixture.session_id, key_id}]
            else
              assert final.approvals == before.approvals
              assert final.sessions == before.sessions
            end
          else
            assert {:error, _} = registration
            assert final.keys == []
            assert final.versions == []
            assert final.approvals == before.approvals
            assert final.sessions == before.sessions
          end

          for peer <- peers do
            assert :peer.call(peer, Fixture, :snapshot, [account.id, fixture]) == final

            assert {:error, _} =
                     :peer.call(peer, Fixture, :register, [operation, fixture, account])

            assert {:ok, %{complete: true}} = :peer.call(peer, Fixture, :complete, [deletion_id])
            assert :peer.call(peer, Fixture, :snapshot, [account.id, fixture]) == final
          end

          assert Security.current(account.id).deleted_at != nil

          assert {:ok, replacement} =
                   :peer.call(third, Fixture, :register, [:manual, fixture, fresh])

          refute replacement.id in Enum.map(final.keys, &elem(&1, 0))

          assert [%{id: replacement_id, user_id: fresh_id}] =
                   Ledger.read!(SSH.Key, user_id: fresh.id)

          assert replacement_id == replacement.id
          assert fresh_id == fresh.id
          assert :peer.call(third, Fixture, :snapshot, [account.id, fixture]) == final
          :ok
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
          Fixture.remove_gate(kind, account.id)
        end
      after
        Fixture.cleanup(fixture, [account, fresh, admin])
      end
    end)
  end

  @spec await_ordering(
          integer(),
          String.t(),
          atom(),
          pid(),
          Fixture.registration(),
          Fixture.snapshot()
        ) :: atom()
  defp await_ordering(holder, account_id, order, observer, fixture, before) do
    await(
      fn ->
        if account_waiter?(holder, account_id) do
          assert :peer.call(observer, Fixture, :snapshot, [account_id, fixture]) == before
          {:ok, :account_fence}
        else
          snapshot = :peer.call(observer, Fixture, :snapshot, [account_id, fixture])

          case {order, snapshot} do
            {:registration_first, %{deletions: [{_, true, 0, false}]}} -> {:ok, :cleanup_overtook}
            {:retirement_first, %{keys: [_ | _]}} -> {:ok, :registration_overtook}
            _ -> :wait
          end
        end
      end,
      "Neither account fence nor completed competing action observed"
    )
  end

  @spec account_waiter?(integer(), String.t()) :: boolean()
  defp account_waiter?(holder, account_id) do
    Fixture.query(
      """
      SELECT count(*) FROM pg_locks waiting JOIN pg_locks held
      ON held.locktype=waiting.locktype AND held.classid=waiting.classid
      AND held.objid=waiting.objid AND held.objsubid=waiting.objsubid
      WHERE waiting.locktype='advisory' AND NOT waiting.granted
      AND held.granted AND held.pid=$1 AND waiting.pid<>held.pid
      AND waiting.classid=((hashtextextended($2,0)::bit(64)::bigint >> 32) & 4294967295)::oid
      AND waiting.objid=(hashtextextended($2,0)::bit(64)::bigint & 4294967295)::oid
      """,
      [holder, "account:" <> account_id]
    ).rows == [[1]]
  end

  @typep outcome ::
           {:ok, term()} | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  # @cc [owner:ghuntley,label:verification] credential-retirement-failed-gate-cleanup
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
