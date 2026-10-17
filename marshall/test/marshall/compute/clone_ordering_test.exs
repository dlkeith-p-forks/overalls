defmodule Marshall.Compute.CloneOrderingTest do
  use ExUnit.Case, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Compute
  alias Marshall.Compute.{Ledger, Operation}
  alias Marshall.CloneVerificationFixture, as: Fixture
  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification] clone-order-three-independent-peers
  # Schedules MUST use three independently booted Marshall BEAMs and Repo pools,
  # with actual public actions and persisted coordinator state as their oracle.
  setup_all do
    # Separate BEAMs, Repo pools and Cedar handles share only PostgreSQL. The
    # parent test node is not counted among the three control-plane instances.
    peers =
      Enum.map(
        [
          :marshall_clone_order_1,
          :marshall_clone_order_2,
          :marshall_clone_order_3
        ],
        &boot_peer/1
      )

    assert length(Enum.uniq(Enum.map(peers, &elem(&1, 1)))) == 3
    %{peers: Enum.map(peers, &elem(&1, 0))}
  end

  setup do
    before = Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &agent_inventory/0)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        assert agent_inventory() == before
      end)
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification] clone-agent-cleanup-complete-inventory
  # Every successful and failed committed schedule MUST restore all agent table
  # identities, including detached history and versions, to its prior inventory.
  # Matching requester ownership MUST NOT permit unrelated history deletion.
  test "cleanup preserves unrelated detached agent history sharing the requester" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      owner = user()

      cleanup_on_exit(fn ->
        Fixture.query("DELETE FROM users WHERE id=$1", [Ecto.UUID.dump!(owner.id)])
      end)

      host = host_fixture()
      cleanup_on_exit(fn -> Fixture.cleanup(host.host.id, owner.id) end)
      {:ok, vm} = Compute.provision(request(), actor: owner)

      assert Fixture.query("SELECT count(*) FROM agent_roots WHERE vm_id=$1", [
               Ecto.UUID.dump!(vm.id)
             ]).rows == [[1]]

      # Detached history deliberately has the same owner but no fixture placement.
      # Seed only resource rows; this control does not claim a VM was admitted.
      detached_vm = Ash.UUID.generate()

      root =
        Ledger.create!(Marshall.Agents.Root, :register, %{vm_id: detached_vm, owner_id: owner.id})

      cleanup_on_exit(fn ->
        Fixture.query("DELETE FROM agent_roots_versions WHERE version_source_id=$1", [
          Ecto.UUID.dump!(root.id)
        ])

        Fixture.query("DELETE FROM agent_roots WHERE id=$1", [Ecto.UUID.dump!(root.id)])
      end)

      thread =
        Ledger.create!(Marshall.Agents.Thread, :open, %{
          root_id: root.id,
          title: "fixture",
          created_by_id: owner.id
        })

      cleanup_on_exit(fn ->
        Fixture.query("DELETE FROM agent_threads_versions WHERE version_source_id=$1", [
          Ecto.UUID.dump!(thread.id)
        ])

        Fixture.query("DELETE FROM agent_threads WHERE id=$1", [Ecto.UUID.dump!(thread.id)])
      end)

      audit =
        Ledger.create!(Marshall.Agents.AuditEvent, :record, %{
          vm_id: detached_vm,
          thread_id: thread.id,
          actor_id: owner.id,
          kind: :agent_registered,
          target_id: root.id,
          outcome: :accepted
        })

      cleanup_on_exit(fn ->
        Fixture.query("DELETE FROM agent_audit_events WHERE id=$1", [Ecto.UUID.dump!(audit.id)])
      end)

      control = detached_agent_inventory(detached_vm)
      assert Enum.all?(control, fn {_table, rows} -> rows != [] end)

      Fixture.cleanup(host.host.id, owner.id)

      assert Fixture.query("SELECT count(*) FROM agent_roots WHERE vm_id=$1", [
               Ecto.UUID.dump!(vm.id)
             ]).rows == [[0]]

      assert detached_agent_inventory(detached_vm) == control
    end)
  end

  # @cc [owner:ghuntley,label:verification] clone-control-setup-cleanup
  # Each committed control resource MUST register exact-ID cleanup immediately
  # after creation, before later setup or assertions can fail. ExUnit callbacks
  # run in reverse registration order before the full agent inventory check.
  @spec cleanup_on_exit((-> term())) :: :ok
  defp cleanup_on_exit(cleanup) do
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, cleanup) end)
  end

  @spec agent_inventory() :: %{String.t() => [[binary()]]}
  defp agent_inventory do
    Map.new(
      ~w(agent_audit_events agent_cli_sessions agent_commands agent_events agent_executors agent_model_calls agent_roots agent_roots_versions agent_search_cache agent_search_usage agent_threads agent_threads_versions agent_turns),
      fn table ->
        key = if table == "agent_search_cache", do: "key", else: "id"
        {table, Fixture.query("SELECT #{key} FROM #{table} ORDER BY #{key}").rows}
      end
    )
  end

  @spec detached_agent_inventory(String.t()) :: %{String.t() => [[binary()]]}
  defp detached_agent_inventory(vm_id) do
    Map.new(
      [
        {"agent_roots", "vm_id=$1"},
        {"agent_roots_versions",
         "version_source_id IN (SELECT id FROM agent_roots WHERE vm_id=$1)"},
        {"agent_threads", "root_id IN (SELECT id FROM agent_roots WHERE vm_id=$1)"},
        {"agent_threads_versions",
         "version_source_id IN (SELECT id FROM agent_threads WHERE root_id IN (SELECT id FROM agent_roots WHERE vm_id=$1))"},
        {"agent_audit_events", "vm_id=$1"}
      ],
      fn {table, predicate} ->
        {table,
         Fixture.query("SELECT id FROM #{table} WHERE #{predicate} ORDER BY id", [
           Ecto.UUID.dump!(vm_id)
         ]).rows}
      end
    )
  end

  @spec boot_peer(atom()) :: {pid(), node()}
  defp boot_peer(name) do
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

  test "activation, new submission and queued retirement do not form a lock cycle", %{
    peers: [first, second, third]
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      host = host_fixture()
      owner = user()
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      {:ok, vm} = Compute.provision(request(), actor: owner)
      [provision] = Ledger.read!(Operation, vm_id: vm.id)
      Fixture.settle(vm, provision, :running)
      {:ok, clone} = Compute.clone(%{vm_id: vm.id, idempotency_key: "head"}, actor: owner)
      gate = Ash.UUID.generate()
      tasks = :ets.new(:clone_tasks, [:set, :private])

      guarded(
        supervisor,
        tasks,
        first,
        gate,
        fn ->
          activation =
            start(supervisor, tasks, first, fn ->
              remote(first, Fixture, :gated_advance, [clone.id, gate], 30_000)
            end)

          await(fn -> is_pid(:peer.call(first, Fixture, :gate_status, [gate])) end)

          submit =
            start(supervisor, tasks, second, fn ->
              remote(
                second,
                Compute,
                :clone,
                [%{vm_id: vm.id, idempotency_key: "following"}, [actor: owner]],
                30_000
              )
            end)

          await(fn -> waiting?("clone-source:" <> vm.id, "ExclusiveLock") end)

          retire =
            start(supervisor, tasks, third, fn ->
              remote(
                third,
                Marshall.CredentialRetirementFixture,
                :retire,
                [admin, owner],
                30_000
              )
            end)

          await(fn -> waiting?("account:" <> owner.id, "ExclusiveLock") end)
          assert Fixture.request(clone.id).phase == :queued
          :ok = :peer.call(first, Fixture, :release, [gate])
          assert {:ok, _} = finish(supervisor, tasks, activation)
          assert {:ok, queued} = finish(supervisor, tasks, submit)
          assert {:ok, _} = finish(supervisor, tasks, retire)
          assert Fixture.request(clone.id).phase == :preparing
          assert Fixture.request(queued.id).phase == :queued
          # Admitted recovery continues, but the following queue entry cannot
          # allocate using the now retired requester.
          assert {:error, _} =
                   :peer.call(second, Compute, :get_clone, [
                     %{request_id: clone.id},
                     [actor: owner]
                   ])

          assert {:ok, _} =
                   call(supervisor, tasks, third, Compute.CloneCoordinator, :advance, [clone.id])

          assert Fixture.request(clone.id).active
          assert Ledger.read!(Compute.VirtualMachine, id: queued.destination_vm_id) == []
        end,
        fn ->
          Fixture.cleanup(host.host.id, owner.id)
          Marshall.PasskeyFixture.cleanup(admin)

          Fixture.query("DELETE FROM account_admin_events WHERE actor_id=$1", [
            Ecto.UUID.dump!(admin.id)
          ])

          Fixture.query("DELETE FROM users WHERE id=$1", [Ecto.UUID.dump!(admin.id)])
        end
      )
    end)
  end

  for first_action <- [:advance, :cancel] do
    @first_action first_action
    test "publication and cancellation serialize with #{@first_action} first", %{
      peers: [first, second, third]
    } do
      supervisor = start_supervised!(Task.Supervisor)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        host = host_fixture()
        owner = user()
        {:ok, vm} = Compute.provision(request(), actor: owner)
        [provision] = Ledger.read!(Operation, vm_id: vm.id)
        Fixture.settle(vm, provision, :running)

        {:ok, clone} =
          Compute.clone(%{vm_id: vm.id, idempotency_key: "publication"}, actor: owner)

        Fixture.prepare(clone.id)
        Fixture.settle_source(clone.id, :stopped)
        Fixture.advance(clone.id)
        Fixture.capture(clone.id)
        Fixture.settle_source(clone.id, :running)
        Fixture.effect(clone.id, :copy, {:dataset_guid, "102"})
        Fixture.advance(clone.id)
        Fixture.effect(clone.id, :adopt, :empty)
        before = Fixture.snapshot(clone.id)
        assert before.phase == :publishing
        assert before.source_restored_at
        gate = Ash.UUID.generate()
        tasks = :ets.new(:clone_tasks, [:set, :private])

        guarded(
          supervisor,
          tasks,
          first,
          gate,
          fn ->
            leading =
              start(supervisor, tasks, first, fn ->
                remote(first, Fixture, :gated, [clone.id, gate, @first_action, owner], 30_000)
              end)

            await(fn -> is_pid(:peer.call(first, Fixture, :gate_status, [gate])) end)

            following =
              start(supervisor, tasks, second, fn ->
                case @first_action do
                  :advance ->
                    remote(
                      second,
                      Compute,
                      :cancel_clone,
                      [%{request_id: clone.id}, [actor: owner]],
                      30_000
                    )

                  :cancel ->
                    remote(second, Compute.CloneCoordinator, :advance, [clone.id], 30_000)
                end
              end)

            await(fn -> waiting?("clone-source:" <> vm.id, "ExclusiveLock") end)
            assert :peer.call(third, Fixture, :snapshot, [clone.id]) == before
            :ok = :peer.call(first, Fixture, :release, [gate])
            assert {:ok, _} = finish(supervisor, tasks, leading)
            result = finish(supervisor, tasks, following)
            current = :peer.call(third, Fixture, :snapshot, [clone.id])

            if @first_action == :advance do
              assert {:error, _} = result
              assert current.published_at
              assert current.cancel_requested_at == nil
              assert current.phase == :cleaning
              assert [_] = Ledger.read!(Operation, vm_id: clone.destination_vm_id)
            else
              assert {:ok, _} = result
              assert current.cancel_requested_at
              assert current.published_at == nil
              assert current.phase == :cancelling
              assert Ledger.read!(Operation, vm_id: clone.destination_vm_id) == []
            end

            for peer <- [first, second, third] do
              assert {:ok, _} =
                       call(supervisor, tasks, peer, Compute.CloneCoordinator, :advance, [
                         clone.id
                       ])

              assert :peer.call(peer, Fixture, :snapshot, [clone.id]) == current
            end
          end,
          fn ->
            Fixture.cleanup(host.host.id, owner.id)
          end
        )
      end)
    end
  end

  test "revocation committed while activation waits is checked before any allocation", %{
    peers: [first, second, third]
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      host = host_fixture()
      owner = user()
      manager = user()
      {:ok, vm} = Compute.provision(request(), actor: owner)
      [provision] = Ledger.read!(Operation, vm_id: vm.id)
      Fixture.settle(vm, provision, :running)

      grant = %{
        vm_id: vm.id,
        email: to_string(manager.email),
        role: :manager,
        idempotency_key: Ash.UUID.generate()
      }

      {:ok, _} = Marshall.Access.set_access(grant, actor: owner)
      {:ok, clone} = Compute.clone(%{vm_id: vm.id, idempotency_key: "revoked"}, actor: manager)
      gate = Ash.UUID.generate()
      tasks = :ets.new(:clone_tasks, [:set, :private])

      guarded(
        supervisor,
        tasks,
        first,
        gate,
        fn ->
          activation =
            start(supervisor, tasks, first, fn ->
              remote(first, Fixture, :gated_advance, [clone.id, gate], 30_000)
            end)

          await(fn -> is_pid(:peer.call(first, Fixture, :gate_status, [gate])) end)

          assert {:ok, _} =
                   call(supervisor, tasks, second, Marshall.Access, :set_access, [
                     %{grant | role: :revoked, idempotency_key: Ash.UUID.generate()},
                     [actor: owner]
                   ])

          assert [] ==
                   :peer.call(third, Ledger, :read!, [
                     Marshall.Access.Grant,
                     [vm_id: vm.id, user_id: manager.id]
                   ])

          :peer.call(first, Fixture, :release, [gate])
          assert {:ok, _} = finish(supervisor, tasks, activation)
          current = :peer.call(third, Fixture, :snapshot, [clone.id])
          assert {current.phase, current.failure, current.active} == {:failed, "forbidden", false}
          assert Ledger.read!(Compute.VirtualMachine, id: clone.destination_vm_id) == []
          assert Ledger.read!(Compute.CloneEffect, clone_request_id: clone.id) == []
          assert Ledger.read!(Compute.TransferSlot, clone_request_id: clone.id) == []
          assert [%{id: operation_id}] = Ledger.read!(Operation, vm_id: vm.id)
          assert operation_id == provision.id
        end,
        fn ->
          Fixture.cleanup(host.host.id, manager.id)
          Fixture.query("DELETE FROM users WHERE id=$1", [Ecto.UUID.dump!(owner.id)])
        end
      )
    end)
  end

  test "admission committed before manager withdrawal retains physical recovery authority", %{
    peers: [first, second, third]
  } do
    supervisor = start_supervised!(Task.Supervisor)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      host = host_fixture()
      owner = user()
      manager = user()
      {:ok, vm} = Compute.provision(request(), actor: owner)
      [provision] = Ledger.read!(Operation, vm_id: vm.id)
      Fixture.settle(vm, provision, :running)

      grant = %{
        vm_id: vm.id,
        email: to_string(manager.email),
        role: :manager,
        idempotency_key: Ash.UUID.generate()
      }

      {:ok, _} = Marshall.Access.set_access(grant, actor: owner)
      {:ok, clone} = Compute.clone(%{vm_id: vm.id, idempotency_key: "admitted"}, actor: manager)
      gate = Ash.UUID.generate()
      tasks = :ets.new(:clone_tasks, [:set, :private])

      guarded(
        supervisor,
        tasks,
        first,
        gate,
        fn ->
          activation =
            start(supervisor, tasks, first, fn ->
              remote(
                first,
                Fixture,
                :gated,
                [clone.id, gate, :advance, nil, :allocation],
                30_000
              )
            end)

          await(fn -> is_pid(:peer.call(first, Fixture, :gate_status, [gate])) end)

          withdrawal =
            start(supervisor, tasks, second, fn ->
              remote(
                second,
                Marshall.Access,
                :set_access,
                [%{grant | role: :revoked, idempotency_key: Ash.UUID.generate()}, [actor: owner]],
                30_000
              )
            end)

          await(fn ->
            Fixture.query(
              "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid WHERE l.locktype='transactionid' AND NOT l.granted AND a.datname=current_database()"
            ).rows == [[1]]
          end)

          assert :peer.call(third, Ledger, :read!, [
                   Compute.VirtualMachine,
                   [id: clone.destination_vm_id]
                 ]) == []

          assert :peer.call(third, Fixture, :request, [clone.id]).phase == :queued
          :peer.call(first, Fixture, :release, [gate])
          assert {:ok, _} = finish(supervisor, tasks, activation)
          assert {:ok, _} = finish(supervisor, tasks, withdrawal)

          assert {:error, _} =
                   call(supervisor, tasks, third, Compute, :cancel_clone, [
                     %{request_id: clone.id},
                     [actor: manager]
                   ])

          assert {:ok, _} =
                   call(supervisor, tasks, third, Compute.CloneCoordinator, :advance, [clone.id])

          assert Fixture.request(clone.id).active
          assert Fixture.request(clone.id).phase == :preparing

          assert [%{owner_id: requester}] =
                   Ledger.read!(Compute.VirtualMachine, id: clone.destination_vm_id)

          assert requester == manager.id

          assert [%{disk_held: true}] =
                   Ledger.read!(Compute.Reservation, vm_id: clone.destination_vm_id)

          assert [_] =
                   Ledger.read!(Compute.CloneEffect, clone_request_id: clone.id, kind: :prepare)
        end,
        fn ->
          Fixture.cleanup(host.host.id, manager.id)
          Fixture.query("DELETE FROM users WHERE id=$1", [Ecto.UUID.dump!(owner.id)])
        end
      )
    end)
  end

  for mode <- [:assertion, :rpc_timeout] do
    @cleanup_mode mode
    test "failed schedule preserves its assertion and drains #{@cleanup_mode}", %{
      peers: [_one, second, third]
    } do
      supervisor = start_supervised!(Task.Supervisor)
      {first, _node} = boot_peer(:marshall_clone_cleanup)
      peer_monitor = Process.monitor(first)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        host = host_fixture()
        owner = user()
        {:ok, vm} = Compute.provision(request(), actor: owner)
        [provision] = Ledger.read!(Operation, vm_id: vm.id)
        Fixture.settle(vm, provision, :running)

        {:ok, clone} =
          Compute.clone(%{vm_id: vm.id, idempotency_key: "cleanup-probe"}, actor: owner)

        gate = Ash.UUID.generate()
        tasks = :ets.new(:clone_tasks, [:set, :private])

        assert_raise ExUnit.AssertionError, ~r/^\s*intentional clone cleanup probe\s*$/, fn ->
          guarded(
            supervisor,
            tasks,
            first,
            gate,
            fn ->
              timeout = if @cleanup_mode == :rpc_timeout, do: 1_000, else: 30_000

              task =
                start(supervisor, tasks, first, fn ->
                  remote(first, Fixture, :gated_advance, [clone.id, gate], timeout)
                end)

              await(fn -> is_pid(:peer.call(first, Fixture, :gate_status, [gate])) end)
              assert :peer.call(third, Fixture, :request, [clone.id]).phase == :queued

              if @cleanup_mode == :rpc_timeout do
                local_monitor = Process.monitor(task.pid)
                assert_receive {:DOWN, ^local_monitor, :process, _, _}, 5_000
                # The local task is gone while its remote transaction still holds
                # the production lock: local liveness cannot authorize deletion.
                assert is_pid(:peer.call(first, Fixture, :gate_status, [gate]))
              else
                start(supervisor, tasks, second, fn ->
                  remote(
                    second,
                    Compute,
                    :cancel_clone,
                    [%{request_id: clone.id}, [actor: owner]],
                    30_000
                  )
                end)

                await(fn -> waiting?("clone-source:" <> vm.id, "ExclusiveLock") end)
              end

              flunk("intentional clone cleanup probe")
            end,
            fn ->
              if @cleanup_mode == :rpc_timeout do
                assert_receive {:DOWN, ^peer_monitor, :process, ^first, _}, 5_000
              else
                assert Fixture.request(clone.id).cancel_requested_at
                assert :peer.call(first, Fixture, :gate_status, [gate]) == nil
              end

              Fixture.cleanup(host.host.id, owner.id)
            end
          )
        end

        assert Ledger.read!(Compute.CloneRequest, id: clone.id) == []
        assert Ledger.read!(Compute.Host, id: host.host.id) == []

        assert Fixture.query("SELECT count(*) FROM users WHERE id=$1", [Ecto.UUID.dump!(owner.id)]).rows ==
                 [[0]]

        assert Fixture.query(
                 "SELECT count(*) FROM oban_jobs WHERE args->'primary_key'->>'id' IN ($1,$2)",
                 [clone.id, provision.id]
               ).rows == [[0]]
      end)
    end
  end

  @typep outcome :: Fixture.outcome(term())

  @spec start(pid(), :ets.tid(), pid(), (-> {:completed, outcome()})) :: Task.t()
  defp start(supervisor, tasks, peer, fun) do
    task = Task.Supervisor.async_nolink(supervisor, fun)
    :ets.insert(tasks, {task.ref, task, peer, :pending})
    task
  end

  @spec remote(pid(), module(), atom(), [term()], pos_integer()) :: {:completed, outcome()}
  defp remote(peer, module, function, arguments, timeout),
    do: :peer.call(peer, Fixture, :invoke, [module, function, arguments], timeout)

  @spec call(pid(), :ets.tid(), pid(), module(), atom(), [term()]) :: term()
  defp call(supervisor, tasks, peer, module, function, arguments) do
    task =
      start(supervisor, tasks, peer, fn -> remote(peer, module, function, arguments, 30_000) end)

    finish(supervisor, tasks, task)
  end

  @spec finish(pid(), :ets.tid(), Task.t()) :: term()
  defp finish(supervisor, tasks, task), do: result!(drain(supervisor, tasks, task))

  # @cc [owner:ghuntley,label:verification] clone-failed-gate-cleanup
  # Every registered mutation MUST be drained, even if its local RPC task exited.
  # Uncertain remote completion MUST stop the peer before fixture deletion.
  # Gate release or cleanup failures MUST NOT replace the original assertion.
  @spec guarded(pid(), :ets.tid(), pid(), String.t(), (-> value), (-> term())) :: value
        when value: term()
  defp guarded(supervisor, tasks, peer, gate, body, cleanup) do
    original = capture(body)
    released = capture(fn -> :peer.call(peer, Fixture, :release, [gate]) end)

    drained =
      for {_ref, task, _peer, _state} <- :ets.tab2list(tasks),
          do: capture(fn -> drain(supervisor, tasks, task) end)

    # If peer shutdown itself fails, retain fixture rows until supervised peer
    # teardown. Never delete while a remote mutation could still be running.
    cleaned =
      if Enum.all?(drained, &match?({:ok, _}, &1)), do: capture(cleanup), else: {:ok, :deferred}

    :ets.delete(tasks)
    value = result!(original)
    result!(released)
    Enum.each(drained, fn drained -> drained |> result!() |> result!() end)
    result!(cleaned)
    value
  end

  @spec drain(pid(), :ets.tid(), Task.t()) :: outcome()
  defp drain(supervisor, tasks, task) do
    case :ets.lookup(tasks, task.ref) do
      [{_, _, _, {:done, outcome}}] ->
        outcome

      [{_, _, peer, :pending}] ->
        outcome =
          case Task.yield(task, 35_000) do
            {:ok, {:completed, outcome}} ->
              outcome

            uncertain ->
              Task.Supervisor.terminate_child(supervisor, task.pid)
              stop_peer(peer)
              {:raised, :exit, {:uncertain_remote_completion, uncertain}, []}
          end

        :ets.insert(tasks, {task.ref, task, peer, {:done, outcome}})
        outcome
    end
  end

  @spec stop_peer(pid()) :: :ok
  defp stop_peer(peer) do
    monitor = Process.monitor(peer)

    try do
      :peer.stop(peer)
    catch
      :exit, {:noproc, _} -> :ok
    end

    receive do
      {:DOWN, ^monitor, :process, ^peer, _} -> :ok
    after
      5_000 -> flunk("Uncertain clone peer did not stop before fixture cleanup")
    end
  end

  @spec capture((-> value)) :: Fixture.outcome(value) when value: term()
  defp capture(fun) do
    try do
      {:ok, fun.()}
    catch
      kind, reason -> {:raised, kind, reason, __STACKTRACE__}
    end
  end

  @spec result!(Fixture.outcome(value)) :: value when value: term()
  defp result!({:ok, value}), do: value
  defp result!({:raised, kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)

  @spec waiting?(String.t(), String.t()) :: boolean()
  defp waiting?(key, mode) do
    Fixture.query(
      """
      SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted AND mode=$2
      AND classid=((hashtextextended($1,0)::bit(64)::bigint >> 32) & 4294967295)::oid
      AND objid=(hashtextextended($1,0)::bit(64)::bigint & 4294967295)::oid
      """,
      [key, mode]
    ).rows == [[1]]
  end

  @spec await((-> boolean()), non_neg_integer()) :: :ok
  defp await(probe, attempts \\ 200)
  defp await(_probe, 0), do: flunk("Expected actual production lock barrier was not observed")

  defp await(probe, attempts) do
    if probe.() do
      :ok
    else
      receive do
      after
        20 -> await(probe, attempts - 1)
      end
    end
  end
end
