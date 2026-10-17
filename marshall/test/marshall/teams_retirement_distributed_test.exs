defmodule Marshall.TeamsRetirementDistributedTest do
  use ExUnit.Case, async: false
  alias Marshall.CommittedFixtureCleanup, as: Cleanup
  require Cleanup
  alias Marshall.Accounts.{Security, UserDeletion}
  alias Marshall.Compute.Ledger
  alias Marshall.Repo
  alias Marshall.TeamRetirementFixture, as: Fixture
  alias Marshall.Teams
  alias Marshall.Teams.{Coordinator, TeamMember}

  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification] team-retirement-three-independent-peers
  # Race fixtures MUST use three distinct BEAM nodes with independent Repo pools
  # and shared committed PostgreSQL state; the parent runner is not a peer.
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
        [:marshall_team_retirement_1, :marshall_team_retirement_2, :marshall_team_retirement_3],
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

  # @cc [owner:ghuntley,label:verification] team-retirement-public-overlap
  # Both serialized orders MUST execute public account deletion and real Teams
  # actions on independent peers. The third peer MUST observe committed state;
  # final account, memberships, transfer, receipt and cleanup state MUST agree.
  for operation <- [:membership, :acceptance], order <- [:team_first, :retirement_first] do
    @operation operation
    @order order
    test "#{operation} and full retirement serialize #{order}", %{peers: [first, second, third]} do
      overlap(@operation, @order, [first, second, third])
    end
  end

  @spec overlap(:membership | :acceptance, :team_first | :retirement_first, [pid()]) :: term()
  defp overlap(operation, order, [first, second, third] = peers) do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      owner = Marshall.ComputeFixtures.user()
      account = Marshall.ComputeFixtures.user()

      {:ok, team} =
        Teams.create_team(
          %{name: "retirement-" <> Ash.UUID.generate(), idempotency_key: Ash.UUID.generate()},
          actor: owner
        )

      Cleanup.protect peers do
        transfer =
          if operation == :acceptance do
            assert {:ok, _} = membership(team.id, account, owner)
            {:ok, offered} = Coordinator.offer(team.id, to_string(account.email), owner)
            offered
          end

        before = :peer.call(third, Fixture, :snapshot, [team.id, account.id])
        gate = System.unique_integer([:positive])
        kind = if order == :retirement_first, do: :retirement, else: operation
        target = if kind == :acceptance, do: transfer.id, else: account.id
        Fixture.query("SELECT pg_advisory_lock($1)", [gate])
        Fixture.install_gate(kind, target, gate)

        Cleanup.protect do
          call_team = fn peer ->
            if operation == :membership do
              :peer.call(
                peer,
                Teams,
                :set_team_member,
                [
                  %{
                    team_id: team.id,
                    email: to_string(account.email),
                    role: :member,
                    idempotency_key: Ash.UUID.generate()
                  },
                  [actor: owner]
                ],
                30_000
              )
            else
              :peer.call(peer, Coordinator, :accept, [transfer.id, account], 30_000)
            end
          end

          call_retire = fn peer ->
            :peer.call(peer, Fixture, :retire, [admin, account], 30_000)
          end

          {leading, following} =
            if order == :team_first,
              do: {call_team, call_retire},
              else: {call_retire, call_team}

          {first_result, {second_result, :ok}} =
            guarded(supervisor, first, gate, fn -> leading.(first) end, fn ->
              holder = await_gate(gate)
              assert :peer.call(third, Fixture, :snapshot, [team.id, account.id]) == before

              guarded(supervisor, second, gate, fn -> following.(second) end, fn ->
                await_account_waiter(holder, account.id)
                assert :peer.call(third, Fixture, :snapshot, [team.id, account.id]) == before
                :ok
              end)
            end)

          {team_result, retirement_result} =
            if order == :team_first,
              do: {first_result, second_result},
              else: {second_result, first_result}

          assert_final(
            operation,
            order,
            team,
            transfer,
            account,
            owner,
            admin,
            team_result,
            retirement_result,
            [first, second, third],
            before
          )
        after
          Fixture.query("SELECT pg_advisory_unlock($1)", [gate])
          Fixture.remove_gate(kind, target)
        end
      after
        Fixture.cleanup(team, [account, owner, admin])
      end
    end)
  end

  @spec membership(String.t(), Marshall.Accounts.User.t(), Marshall.Accounts.User.t()) ::
          {:ok, map()} | {:error, term()}
  defp membership(team, account, owner),
    do:
      Teams.set_team_member(
        %{
          team_id: team,
          email: to_string(account.email),
          role: :member,
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

  @spec assert_final(
          atom(),
          atom(),
          Teams.Team.t(),
          Teams.Transfer.t() | nil,
          Marshall.Accounts.User.t(),
          Marshall.Accounts.User.t(),
          Marshall.Accounts.User.t(),
          term(),
          term(),
          [pid()],
          Fixture.snapshot()
        ) :: :ok
  defp assert_final(
         operation,
         order,
         team,
         transfer,
         account,
         owner,
         admin,
         team_result,
         retirement_result,
         peers,
         before
       ) do
    accepted = operation == :acceptance and order == :team_first
    assert {:ok, _} = if(order == :team_first, do: team_result, else: retirement_result)

    if accepted do
      assert {:error, %Ash.Error.Invalid{errors: [%Marshall.Compute.Error{reason: :team_owner}]}} =
               retirement_result

      assert [%{user_id: owner_id}] = Ledger.read!(TeamMember, team_id: team.id, role: :owner)
      assert owner_id == account.id
      assert Security.current(account.id).deleted_at == nil
      assert Ledger.read!(UserDeletion, user_id: account.id) == []
      final = Fixture.snapshot(team.id, account.id)
      assert final.transfers == [{transfer.id, :accepted}]

      assert final.memberships ==
               Enum.sort([{owner.id, :admin, false}, {account.id, :owner, false}])

      assert final.events ==
               Enum.sort([{account.id, transfer.id, :team_transfer_accept} | before.events])
    else
      assert {:ok, %{id: deletion_id}} = retirement_result
      if order == :retirement_first, do: assert(match?({:error, _}, team_result))
      final = Fixture.snapshot(team.id, account.id)
      assert final.retired
      expected_memberships = [{owner.id, :owner, false}]

      expected_memberships =
        if operation == :acceptance or order == :team_first,
          do: [{account.id, :member, true} | expected_memberships],
          else: expected_memberships

      assert final.memberships == Enum.sort(expected_memberships)
      assert [%{user_id: owner_id}] = Ledger.read!(TeamMember, team_id: team.id)
      assert owner_id == owner.id
      assert final.deletions == [{deletion_id, false, 0, false}]
      changes = [{admin.id, account.id, :user_delete}]

      changes =
        if operation == :acceptance or order == :team_first,
          do: [{admin.id, team.id, :team_membership_change} | changes],
          else: changes

      changes =
        if operation == :membership and order == :team_first,
          do: [{owner.id, team.id, :team_membership_change} | changes],
          else: changes

      changes =
        if operation == :acceptance,
          do: [{admin.id, transfer.id, :team_transfer_cancel} | changes],
          else: changes

      assert final.events == Enum.sort(before.events ++ changes)

      assert final.transfers ==
               if(operation == :acceptance, do: [{transfer.id, :cancelled}], else: [])

      for peer <- peers do
        assert {:ok, %{id: ^deletion_id}} =
                 :peer.call(peer, Fixture, :retire, [admin, account], 30_000)

        assert :peer.call(peer, Fixture, :snapshot, [team.id, account.id]) == final

        assert {:error, _} =
                 :peer.call(peer, Teams, :set_team_member, [
                   %{
                     team_id: team.id,
                     email: to_string(account.email),
                     role: :member,
                     idempotency_key: Ash.UUID.generate()
                   },
                   [actor: owner]
                 ])
      end

      for peer <- peers do
        assert {:ok, %{complete: true}} =
                 :peer.call(
                   peer,
                   Marshall.Accounts.DeleteUserMachines,
                   :run,
                   [
                     %Ash.ActionInput{arguments: %{primary_key: %{"id" => deletion_id}}},
                     [],
                     %{actor: Marshall.Authorization.SystemActor.compute()}
                   ],
                   30_000
                 )
      end

      completed = Fixture.snapshot(team.id, account.id)
      assert completed.deletions == [{deletion_id, true, 0, false}]
      assert %{completed | deletions: final.deletions} == final
    end

    for peer <- peers do
      assert :peer.call(peer, Fixture, :snapshot, [team.id, account.id]) ==
               Fixture.snapshot(team.id, account.id)
    end

    :ok
  end

  @typep outcome ::
           {:ok, term()} | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  # @cc [owner:ghuntley,label:verification] team-retirement-failed-gate-cleanup
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

  @spec await_account_waiter(integer(), String.t()) :: :ok
  defp await_account_waiter(holder, account_id) do
    await(
      fn ->
        rows =
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
          ).rows

        if rows == [[1]], do: {:ok, :ok}, else: :wait
      end,
      "Competing production operation did not wait on the account admission fence"
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
