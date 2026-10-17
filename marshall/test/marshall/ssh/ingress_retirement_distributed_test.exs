defmodule Marshall.SSH.IngressRetirementDistributedTest do
  @moduledoc """
  Renewal-versus-retirement schedules over three independent Marshall BEAMs.
  Establishes the exact authority windows of an Audi SSH session:
  (1) an uncommitted retirement transaction never blocks renewal,
  (2) the committed tombstone alone denies renewal and admission before bounded
  durable cleanup runs, and
  (3) committed cleanup keeps every fence closed on every peer.
  """
  use ExUnit.Case, async: false
  alias Marshall.IngressRetirementFixture, as: Fixture
  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000

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

  # @cc [owner:ghuntley,label:verification;concurrency] ingress-retirement-three-peers
  # Production open/renew/retire/cleanup actions MUST execute on three
  # independent BEAMs with separate Repo pools; the runner is not a peer.
  setup_all do
    peers =
      for number <- 1..3 do
        name = String.to_atom("marshall_ingress_retirement_#{number}_#{System.pid()}")

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

  test "an uncommitted retirement cannot extend authority; the committed tombstone ends it", %{
    peers: [first, second, third]
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      fixture = Fixture.setup!()

      try do
        assert {:ok, session} = call(first, :open, [fixture])
        assert {:ok, renewed} = call(second, :renew, [fixture, session.ticket])
        assert renewed.binding.session_id == session.binding.session_id
        before = call(third, :snapshot, [fixture])
        refute before.retired
        assert [_] = before.grants
        assert [_] = before.keys
        assert [_] = before.sessions

        gate = System.unique_integer([:positive])
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])
        Fixture.install_gate(fixture.member.id, gate)

        {retirement, :ok} =
          try do
            guarded(
              supervisor,
              first,
              gate,
              fn -> call(first, :retire, [fixture.admin, fixture.member]) end,
              fn ->
                await_gate(gate)
                # Committed-state window: the still-blocked retirement has not
                # changed durable authority, so renewal remains admitted.
                assert {:ok, _} = call(second, :renew, [fixture, session.ticket])
                assert call(third, :snapshot, [fixture]) == before
                :ok
              end
            )
          after
            Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
            Fixture.remove_gate(fixture.member.id)
          end

        assert {:ok, deletion} = retirement
        tombstoned = call(third, :snapshot, [fixture])
        assert tombstoned.retired
        # The committed tombstone alone closes renewal and admission while the
        # member's grant and key rows remain durably live (pre-cleanup window).
        assert [_] = tombstoned.grants
        assert [_] = tombstoned.keys
        assert {:error, _} = call(first, :renew, [fixture, session.ticket])
        assert {:error, _} = call(second, :renew, [fixture, session.ticket])
        assert {:error, _} = call(first, :open, [fixture])

        assert {:ok, %{complete: true}} = call(third, :complete, [deletion.id])
        final = call(third, :snapshot, [fixture])
        assert final.retired
        assert [] == final.grants
        assert [] == final.keys
        assert final.deletions == [{deletion.id, true}]

        for peer <- [first, second, third] do
          assert call(peer, :snapshot, [fixture]) == final
          assert {:error, _} = call(peer, :renew, [fixture, session.ticket])
          assert {:error, _} = call(peer, :open, [fixture])
        end
      after
        Fixture.cleanup!(fixture)
      end
    end)
  end

  @spec call(pid(), atom(), [term()]) :: term()
  defp call(peer, operation, args), do: :peer.call(peer, Fixture, operation, args, 30_000)

  @typep outcome ::
           {:ok, term()} | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}
  # @cc [owner:ghuntley,label:verification] ingress-retirement-failed-gate-cleanup
  # Failed assertions MUST release the gate and drain gated production calls
  # before fixture cleanup; the original assertion MUST remain the failure.
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
        "Production retirement did not reach its target write gate"
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
