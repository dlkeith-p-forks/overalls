defmodule Marshall.Administration.JobHistoryDistributedTest do
  use ExUnit.Case, async: false
  alias Marshall.Accounts.Security
  alias Marshall.JobHistoryFixture, as: Fixture
  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification] job-history-three-independent-peers
  # Every schedule MUST use three distinct Marshall BEAMs and Repo pools; the
  # coordinator MUST NOT count as one of those instances.
  setup_all do
    # Separate BEAMs, Repo pools and Cedar handles share only PostgreSQL. The
    # parent test node is not counted among the three control-plane instances.
    peers =
      Enum.map(
        [
          :marshall_job_history_1,
          :marshall_job_history_2,
          :marshall_job_history_3
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

  for competitor <- [:lock, :signout, :demote, :prune, :complete],
      order <- [:retry_first, :change_first] do
    @competitor competitor
    @order order
    test "retry and #{@competitor} serialize #{@order}", %{peers: peers} do
      overlap(@competitor, @order, peers)
    end
  end

  @spec overlap(Fixture.operation(), :retry_first | :change_first, [pid()]) :: :ok
  defp overlap(competitor, order, [first, second, third] = peers) do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      operator = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      job = Fixture.insert("job_race_#{System.unique_integer([:positive])}")
      Fixture.transition(job.id, "discarded", 1, 1)
      request = Ash.UUID.generate()
      leading = if order == :retry_first, do: :retry, else: competitor
      following = if order == :retry_first, do: competitor, else: :retry
      gate = System.unique_integer([:positive])

      try do
        before = :peer.call(third, Fixture, :snapshot, [job.id, admin.id])
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])
        Fixture.install_gate(leading, job.id, admin.id, gate)

        try do
          {one, {two, observed}} =
            guarded(
              supervisor,
              first,
              gate,
              fn ->
                remote(
                  first,
                  Fixture,
                  :act,
                  [leading, job.id, admin, operator, request],
                  30_000
                )
              end,
              fn ->
                holder = await_gate(gate)
                assert :peer.call(third, Fixture, :snapshot, [job.id, admin.id]) == before

                guarded(
                  supervisor,
                  second,
                  gate,
                  fn ->
                    remote(
                      second,
                      Fixture,
                      :act,
                      [following, job.id, admin, operator, request],
                      30_000
                    )
                  end,
                  fn -> await_ordering(holder, third, job.id, admin, before) end
                )
              end
            )

          {retry, change} = if order == :retry_first, do: {one, two}, else: {two, one}
          assert observed == :blocked
          if competitor in [:lock, :signout, :demote], do: assert(match?({:ok, _}, change))

          if order == :retry_first,
            do: assert(match?({:ok, %{accepted: true}}, retry)),
            else: assert(match?({:error, _}, retry))

          after_change = :peer.call(third, Fixture, :snapshot, [job.id, admin.id])
          assert length(after_change.receipts) == if(order == :retry_first, do: 1, else: 0)

          if order == :retry_first do
            assert [%{action: :retry_job, resource_id: resource_id, request_id: ^request}] =
                     after_change.receipts

            assert resource_id == to_string(job.id)
          end

          if competitor == :prune do
            assert after_change.raw == nil
            assert [%{raw_present: false}] = after_change.snapshot
          else
            expected =
              cond do
                competitor == :complete -> "completed"
                order == :retry_first -> "available"
                true -> "discarded"
              end

            assert after_change.raw.state == expected
          end

          expected_states =
            [:available, :discarded] ++
              if(order == :retry_first, do: [:available], else: []) ++
              if(competitor == :complete, do: [:completed], else: [])

          assert Enum.map(after_change.events, & &1.state) == expected_states

          for peer <- peers do
            assert :peer.call(peer, Fixture, :snapshot, [job.id, admin.id]) == after_change

            refusal =
              Task.Supervisor.async_nolink(supervisor, fn ->
                remote(
                  peer,
                  Fixture,
                  :act,
                  [:retry, job.id, admin, operator, Ash.UUID.generate()],
                  30_000
                )
              end)

            assert {:error, _} = result!(drain(supervisor, peer, refusal))

            assert :peer.call(peer, Fixture, :snapshot, [job.id, admin.id]) == after_change
          end

          :ok
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
          Fixture.remove_gate(leading, job.id)
        end
      after
        Fixture.cleanup([job.id], [admin, operator])
      end
    end)
  end

  @spec await_ordering(
          integer(),
          pid(),
          pos_integer(),
          Marshall.Accounts.User.t(),
          Fixture.snapshot()
        ) :: atom()
  defp await_ordering(holder, observer, id, admin, before) do
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

          :peer.call(observer, Fixture, :snapshot, [id, admin.id]) != before ->
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

  # @cc [owner:ghuntley,label:verification] job-history-failed-gate-cleanup
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
