defmodule MarshallWeb.CrossReplicaRevocationTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  require Marshall.CommittedFixtureCleanup, as: Cleanup

  alias Marshall.Accounts.{Security, User}
  alias Marshall.ReadRevocationFixture, as: Reads
  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000

  @peers [:marshall_read_revocation_1, :marshall_read_revocation_2, :marshall_read_revocation_3]

  # @cc [owner:ghuntley,label:verification] read-revocation-fixture-preservation
  # Every schedule MUST restore the complete committed public-table row
  # inventory, including historical rows unrelated to its fixtures. ExUnit
  # reports this independent teardown check separately from a body failure.
  setup do
    before =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(
        Repo,
        &Marshall.CommittedFixtureInventory.snapshot/0
      )

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Marshall.CommittedFixtureInventory.assert_restored!(before)
      end)
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification] read-revocation-three-peers
  # Schedules MUST execute reads and invalidations on three distinct BEAM nodes
  # with independent Repo pools sharing committed PostgreSQL state. The parent
  # runner coordinates but MUST NOT supply the durable observations it asserts.
  setup_all do
    peers =
      Enum.map(@peers, fn name ->
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
        peer
      end)

    assert length(Enum.uniq(Enum.map(peers, &:peer.call(&1, :erlang, :node, [])))) == 3
    %{peers: peers}
  end

  test "administrative revocation on one replica refuses every protected read on the others",
       %{peers: [first, second, third]} do
    unboxed(fn ->
      {admin, reader, token} = actor_pair()
      jti = Security.jti(reader)

      Cleanup.protect [first, second, third] do
        assert_durable([first, second, third], jti, %{purpose: "user", expired: false})
        assert_surfaces([first, second, third], reader, token, :allow)

        assert {:ok, %{revoked: 1}} =
                 :peer.call(
                   second,
                   Reads,
                   :invalidate,
                   [:revoke_sessions, admin, token, reader],
                   30_000
                 )

        assert_durable([first, second, third], jti, Reads.expected_durable(:revoke_sessions))
        assert_surfaces([first, second, third], reader, token, :refuse)
      after
        drop_actor_pair(admin, reader)
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification] read-revocation-invalidation-kinds
  # Each fixed schedule MUST exercise one real invalidation kind against a
  # distinct revoking replica so generated sampling is never the only positive
  # coverage.
  test "every invalidation kind refuses reads on every replica", %{peers: peers} do
    for {kind, revoker} <- [revoke_sessions: 0, token_revoke: 1, expire: 2] do
      assert_schedule(peers, kind, revoker)
    end
  end

  # @cc [owner:ghuntley,label:verification] read-revocation-generated-schedules
  # Generated schedules MUST vary the invalidation kind, the revoking replica
  # and the per-replica check order. Every generated schedule MUST recheck the
  # raw durable oracle and the four protected read decisions on all three
  # replicas.
  property "generated invalidation schedules refuse on every replica", %{peers: peers} do
    check all(
            kind <- member_of([:revoke_sessions, :token_revoke, :expire]),
            revoker <- member_of([0, 1, 2]),
            order <- shuffle([0, 1, 2]),
            max_runs: 6
          ) do
      assert_schedule(Enum.map(order, &Enum.at(peers, &1)), kind, revoker)
    end
  end

  @spec assert_schedule([pid()], Reads.invalidation_kind(), non_neg_integer()) :: :ok
  defp assert_schedule(peers, kind, revoker) do
    unboxed(fn ->
      {admin, reader, token} = actor_pair()
      jti = Security.jti(reader)

      Cleanup.protect peers do
        assert_durable(peers, jti, %{purpose: "user", expired: false})
        assert_surfaces(peers, reader, token, :allow)

        assert invalidate_on(Enum.at(peers, revoker), kind, admin, reader, token)

        assert_durable(peers, jti, Reads.expected_durable(kind))
        assert_surfaces(peers, reader, token, :refuse)
      after
        drop_actor_pair(admin, reader)
      end
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification] read-revocation-commit-boundary
  # An in-flight revocation MUST pin the documented propagation bound:
  # concurrent replica reads may allow while the revocation transaction is
  # uncommitted and MUST refuse after commit. The fixture MUST pause the real
  # account-locked revocation through a target-specific trigger without
  # supplying its locks or altering its statements.
  test "a replica read racing revocation obeys the commit boundary",
       %{peers: [first, second, third]} do
    supervisor = start_supervised!(Task.Supervisor)

    unboxed(fn ->
      {admin, reader, token} = actor_pair()
      jti = Security.jti(reader)
      gate = System.unique_integer([:positive])

      Cleanup.protect [first, second, third] do
        Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_lock($1)", [gate], log: false)
        Marshall.RememberedLoginFixture.install_revoke_gate(reader.id, gate)

        try do
          {result, :ok} =
            with_revocation(
              supervisor,
              first,
              gate,
              fn ->
                :peer.call(
                  first,
                  Marshall.RememberedLoginFixture,
                  :revoke,
                  [admin, reader.id],
                  30_000
                )
              end,
              fn ->
                _waiter = await_gate_waiter(gate, 100)

                assert %{purpose: "user", expired: false} =
                         :peer.call(second, Reads, :durable_login_state, [jti])

                assert_surfaces([second, third], reader, token, :allow)
              end
            )

          assert {:ok, %{revoked: 1}} = result
        after
          Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_unlock($1)", [gate], log: false)
          Marshall.RememberedLoginFixture.remove_revoke_gate(reader.id)
        end

        assert_durable([first, second, third], jti, Reads.expected_durable(:revoke_sessions))
        assert_surfaces([first, second, third], reader, token, :refuse)
      after
        drop_actor_pair(admin, reader)
      end
    end)
  end

  @typep revocation_outcome ::
           {:ok, term()}
           | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  # The body observes the in-flight revocation; the gate is always released
  # before the real revocation drains, including when the body fails.
  @spec with_revocation(Task.Supervisor.t(), pid(), integer(), (-> term()), (-> result)) ::
          {term(), result}
        when result: term()
  defp with_revocation(supervisor, peer, gate, operation, body) do
    task = Task.Supervisor.async_nolink(supervisor, operation)
    receipt = make_ref()

    body_result =
      try do
        {:ok, body.()}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      after
        try do
          Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_unlock($1)", [gate], log: false)
        after
          send(self(), {receipt, drain_revocation(supervisor, peer, task)})
        end
      end

    receive do
      {^receipt, task_result} ->
        result = resolve_revocation!(body_result)
        {resolve_revocation!(task_result), result}
    end
  end

  @spec drain_revocation(Task.Supervisor.t(), pid(), Task.t()) :: revocation_outcome()
  defp drain_revocation(supervisor, peer, task) do
    try do
      {:ok, Task.await(task, 35_000)}
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        Task.Supervisor.terminate_child(supervisor, task.pid)
        # An RPC failure stops this owned peer before fixture rows are removed;
        # peers are shared, so such a run cannot pass as distributed evidence.
        :peer.stop(peer)
        {:raised, kind, reason, stacktrace}
    end
  end

  @spec resolve_revocation!(revocation_outcome()) :: term()
  defp resolve_revocation!({:ok, result}), do: result

  defp resolve_revocation!({:raised, kind, reason, stacktrace}),
    do: :erlang.raise(kind, reason, stacktrace)

  @spec await_gate_waiter(integer(), non_neg_integer()) :: integer()
  defp await_gate_waiter(_gate, 0),
    do: flunk("revocation did not reach the in-flight durability gate")

  defp await_gate_waiter(gate, attempts) do
    case Ecto.Adapters.SQL.query!(
           Repo,
           "SELECT pid FROM pg_locks WHERE locktype='advisory' AND objid=$1 AND NOT granted",
           [gate],
           log: false
         ).rows do
      [[pid]] ->
        pid

      [] ->
        Process.sleep(20)
        await_gate_waiter(gate, attempts - 1)
    end
  end

  # @cc [owner:ghuntley,label:verification] read-revocation-partition-fail-closed
  # A replica cut off from durable authority MUST NOT serve protected reads:
  # its checks raise rather than return an allowed decision. On rejoin it MUST
  # observe and enforce the committed revocation without any explicit invalidation
  # message; refusal follows the first completed recheck.
  test "a replica partitioned during revocation fails closed and enforces it on rejoin",
       %{peers: [first, second, third]} do
    unboxed(fn ->
      {admin, reader, token} = actor_pair()
      jti = Security.jti(reader)

      Cleanup.protect [first, second, third] do
        assert_surfaces([first, second, third], reader, token, :allow)

        assert :ok =
                 :peer.call(second, Supervisor, :terminate_child, [
                   Marshall.Supervisor,
                   Repo
                 ])

        assert {:ok, %{revoked: 1}} =
                 :peer.call(
                   first,
                   Reads,
                   :invalidate,
                   [:revoke_sessions, admin, token, reader],
                   30_000
                 )

        assert_surfaces([first, third], reader, token, :refuse)

        assert :failed = served_decision(second, :browser_read, [reader])
        assert :failed = served_decision(second, :control_room_read, [reader])
        assert :failed = served_decision(second, :export_read, [reader, token])
        assert :failed = served_decision(second, :projection_read, [reader])
        assert :failed = served_decision(second, :durable_login_state, [jti])

        assert {:ok, _pid} =
                 :peer.call(second, Supervisor, :restart_child, [
                   Marshall.Supervisor,
                   Repo
                 ])

        await_rejoin_readiness(second)

        assert_durable([second], jti, Reads.expected_durable(:revoke_sessions))
        assert_surfaces([second], reader, token, :refuse)
      after
        restart_repo(second)
        drop_actor_pair(admin, reader)
      end
    end)
  end

  @spec restart_repo(pid()) :: :ok
  defp restart_repo(peer) do
    try do
      :peer.call(peer, Supervisor, :restart_child, [Marshall.Supervisor, Repo])
      :ok
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  # A successful :peer.call reports the decision; a raise or exit on a
  # partitioned replica is fail-closed evidence, never a served refusal.
  @spec served_decision(pid(), atom(), [term()]) :: {:served, term()} | :failed
  defp served_decision(peer, function, args) do
    try do
      {:served, :peer.call(peer, Reads, function, args, 30_000)}
    rescue
      _ -> :failed
    catch
      _, _ -> :failed
    end
  end

  @spec await_rejoin_readiness(pid()) :: :ok
  defp await_rejoin_readiness(peer), do: await_rejoin_readiness(peer, 100)

  @spec await_rejoin_readiness(pid(), non_neg_integer()) :: :ok
  defp await_rejoin_readiness(_peer, 0),
    do: flunk("rejoined replica did not recover its durable store connection")

  defp await_rejoin_readiness(peer, attempts) do
    case served_decision(peer, :durable_login_state, [""]) do
      :failed ->
        Process.sleep(20)
        await_rejoin_readiness(peer, attempts - 1)

      {:served, :absent} ->
        :ok
    end
  end

  # @cc [owner:ghuntley,label:verification] read-revocation-inventory-cleanup
  # Teardown MUST remove exactly this schedule's fixture rows: account events
  # naming its actors, their passkey, verification, challenge and token rows,
  # and the users themselves. Unrelated committed rows MUST survive unchanged.
  @spec drop_actor_pair(User.t(), User.t()) :: :ok
  defp drop_actor_pair(admin, reader) do
    for actor <- [admin, reader], do: Marshall.PasskeyFixture.cleanup(actor)

    ids = Enum.map([admin.id, reader.id], &Ecto.UUID.dump!/1)

    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM account_admin_events WHERE actor_id = ANY($1) OR target_id = ANY($1)",
      [ids],
      log: false
    )

    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM users WHERE id = ANY($1)", [ids], log: false)
    :ok
  end

  @spec actor_pair() :: {User.t(), User.t(), String.t()}
  defp actor_pair do
    admin = Marshall.PasskeyFixture.verified_session(Marshall.PasskeyFixture.user(true))
    {reader, token} = Marshall.PasskeyFixture.login(Marshall.PasskeyFixture.user())
    {admin, reader, token}
  end

  @spec invalidate_on(pid(), Reads.invalidation_kind(), User.t(), User.t(), String.t()) ::
          boolean()
  defp invalidate_on(peer, kind, admin, reader, token) do
    case :peer.call(peer, Reads, :invalidate, [kind, admin, token, reader], 30_000) do
      {:ok, %{revoked: count}} when is_integer(count) and count > 0 -> true
      :ok -> true
      _other -> false
    end
  end

  @spec assert_durable([pid()], String.t(), :absent | %{purpose: String.t(), expired: boolean()}) ::
          :ok
  defp assert_durable(peers, jti, expected) do
    for peer <- peers do
      assert ^expected = :peer.call(peer, Reads, :durable_login_state, [jti])
    end

    :ok
  end

  @spec assert_surfaces([pid()], User.t(), String.t(), Reads.decision()) :: :ok
  defp assert_surfaces(peers, reader, token, expected) do
    for peer <- peers do
      assert ^expected = :peer.call(peer, Reads, :browser_read, [reader])
      assert ^expected = :peer.call(peer, Reads, :control_room_read, [reader])
      assert ^expected = :peer.call(peer, Reads, :export_read, [reader, token])
      assert ^expected = :peer.call(peer, Reads, :projection_read, [reader])
    end

    :ok
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
