defmodule Marshall.Agents.AgentContextRecoveryDistributedTest do
  use ExUnit.Case, async: false

  import Marshall.ComputeFixtures

  alias Marshall.Agents.{
    ContextCheckpoint,
    Event,
    PlanningQuestion,
    SkillOperation,
    SkillRevision,
    Thread,
    Turn
  }

  alias Marshall.AgentContextRecoveryFixture, as: Recovery
  alias Marshall.Agents.{Compaction, Planning, Skills}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.CommittedFixtureCleanup, as: Cleanup
  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification;recovery] agent-context-independent-process-recovery
  # Durable context, planning and managed-skill records MUST remain recoverable
  # by a distinct Marshall process after the process which admitted or dispatched
  # the operation is stopped. This suite observes committed PostgreSQL state only;
  # it does not claim native guest or provider completion.

  # @cc [owner:ghuntley,label:verification] agent-context-committed-inventory
  # Every recovery test MUST restore the complete pre-test public row inventory,
  # including historical rows and existing image records, on success or failure.
  # Fixture teardown MUST stop all peers before any owned records are removed.
  setup do
    {before, images_before} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        assert [] = Enum.filter(Ledger.read!(Marshall.Compute.Host), & &1.enabled)
        {Marshall.CommittedFixtureInventory.snapshot(), Cleanup.fixture_image_ids()}
      end)

    peers = Enum.map(1..3, &start_peer/1)

    on_exit(fn ->
      Enum.each(peers, &stop_peer/1)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Cleanup.images!(Cleanup.fixture_image_ids() -- images_before)
        Marshall.CommittedFixtureInventory.assert_restored!(before)
      end)
    end)

    %{peers: peers}
  end

  test "pending planning questions survive the admitting process loss", %{
    peers: [writer, reader, _] = peers
  } do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      %{actor: actor, thread: thread, turn: turn} = planning_fixture(peers)
      call = question_call()

      assert %PlanningQuestion{id: question_id} =
               remote(writer, Recovery, :request_questions, [thread.id, turn.id, call])

      stop_peer(writer)

      assert [%PlanningQuestion{id: ^question_id, status: :pending}] =
               Ledger.read!(PlanningQuestion, id: question_id)

      answer = %{
        question_id: question_id,
        answers: %{"approach" => %{"selected" => "First", "text" => ""}},
        request_key: Ash.UUID.generate()
      }

      assert %{status: :answered} =
               remote(reader, Planning, :answer, [answer, [actor: actor]])

      assert [%{status: :answered}] = Ledger.read!(PlanningQuestion, id: question_id)
      assert [_] = Ledger.read!(Event, turn_id: turn.id, kind: :tool_result)
      refute Planning.awaiting?(thread.id)
    end)
  end

  test "a compacted context checkpoint is projected after its writer process loss", %{
    peers: [writer, reader, _] = peers
  } do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      %{thread: thread, turn: turn} = context_fixture(peers)

      assert %ContextCheckpoint{generation: 1} =
               remote(writer, Recovery, :install_checkpoint, [turn.id])

      stop_peer(writer)

      assert %{checkpoint: projection_checkpoint, snapshot: projection_snapshot} =
               remote(reader, Recovery, :project, [thread.id, turn.id])

      projection = %{checkpoint: projection_checkpoint, snapshot: projection_snapshot}
      assert projection.checkpoint.generation == 1
      assert projection.checkpoint.state == %{"summary" => "Recovered compacted context"}
      assert projection.snapshot.turn_id == turn.id
    end)
  end

  test "a compaction plan can be reconstructed by another process after worker loss", %{
    peers: [writer, reader, _]
  } do
    request = compaction_request()

    assert %{kind: :summary, request: first_request, source_digest: digest} =
             remote(writer, Compaction, :prepare, [request])

    stop_peer(writer)

    assert %{kind: :summary, request: ^first_request, source_digest: ^digest} =
             remote(reader, Compaction, :prepare, [request])
  end

  test "queued managed skill installation is dispatched and completed by another process", %{
    peers: [writer, dispatcher, completer] = peers
  } do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      %{owner: owner, thread: thread} = skill_fixture(peers)

      arguments = %{
        thread_id: thread.id,
        url: "https://github.com/example/skills",
        subdirectory: "review",
        idempotency_key: Ash.UUID.generate()
      }

      assert %SkillOperation{id: operation_id, status: :queued} =
               remote(writer, Recovery, :install_skill, [arguments, owner])

      stop_peer(writer)

      assert %SkillOperation{id: ^operation_id, status: :dispatched} =
               remote(dispatcher, Recovery, :dispatch_skill, [operation_id])

      stop_peer(dispatcher)

      result = skill_result(operation_id, thread.machine_id, thread.machine_key)

      assert %SkillOperation{id: ^operation_id, status: :completed} =
               remote(completer, Recovery, :complete_skill, [operation_id, result])

      assert [%{status: :completed}] = Ledger.read!(SkillOperation, id: operation_id)

      assert [%{operation_id: ^operation_id}] =
               Ledger.read!(SkillRevision, operation_id: operation_id)

      assert {:ok, %{items: [%{status: :ready}]}} = Skills.list(thread.id, actor: owner)
    end)
  end

  @spec start_peer(pos_integer()) :: pid()
  defp start_peer(index) do
    name =
      String.to_atom(
        "marshall_agent_context_recovery_#{index}_#{System.unique_integer([:positive])}"
      )

    peer =
      start_supervised!(%{
        id: name,
        start:
          {:peer, :start_link,
           [
             %{
               name: name,
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
      :peer.call(peer, Application, :put_env, [:marshall, Repo, repo_config, [persistent: true]])

    :ok = :peer.call(peer, Application, :put_env, [:logger, :level, :error, [persistent: true]])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:marshall], 30_000)
    peer
  end

  @spec stop_peer(pid()) :: :ok
  defp stop_peer(peer) do
    if Process.alive?(peer), do: :peer.stop(peer)
    :ok
  end

  @spec remote(pid(), module(), atom(), [term()]) :: term()
  defp remote(peer, module, function, arguments),
    do:
      :peer.call(
        peer,
        Marshall.AgentContextRecoveryFixture,
        :invoke,
        [module, function, arguments],
        30_000
      )
      |> unwrap_remote!()

  @spec unwrap_remote!(
          {:completed, {:ok, term()} | {:error, term()} | {:raised, atom(), term(), list()}}
        ) :: term()
  defp unwrap_remote!({:completed, {:ok, value}}), do: value

  defp unwrap_remote!({:completed, {:error, reason}}),
    do: flunk("remote call failed: #{inspect(reason)}")

  defp unwrap_remote!({:completed, {:raised, kind, reason, stacktrace}}),
    do: :erlang.raise(kind, reason, stacktrace)

  @spec planning_fixture([pid()]) :: %{
          actor: Marshall.Accounts.User.t(),
          thread: Thread.t(),
          turn: Turn.t()
        }
  defp planning_fixture(peers) do
    {:ok, {actor, vm}} =
      Ledger.transaction(fn ->
        host_fixture()
        actor = user()
        {:ok, vm} = Marshall.Compute.provision(request(), actor: actor)
        {actor, vm}
      end)

    owned_cleanup(peers, vm, [actor])
    [root] = Ledger.read!(Marshall.Agents.Root, vm_id: vm.id)
    [thread] = Ledger.read!(Thread, root_id: root.id)

    {:ok, {thread, turn}} =
      Ledger.transaction(fn ->
        turn =
          Ledger.create!(Turn, :enqueue, %{
            thread_id: thread.id,
            actor_id: actor.id,
            request_key: Ash.UUID.generate(),
            ordinal: 1,
            prompt: "Plan the change.",
            collaboration_mode: :plan
          })

        turn = Ledger.update!(turn, :transition, %{status: :running, started_at: Ledger.now()})
        thread = Ledger.update!(thread, :advance, %{active_turn_id: turn.id})
        thread = Ledger.update!(thread, :set_context, %{collaboration_mode: :plan})
        {thread, turn}
      end)

    %{actor: actor, thread: thread, turn: turn}
  end

  @spec context_fixture([pid()]) :: %{
          owner: Marshall.Accounts.User.t(),
          vm: VirtualMachine.t(),
          thread: Thread.t(),
          turn: Turn.t()
        }
  defp context_fixture(peers) do
    {:ok, fixture} = Ledger.transaction(fn -> Marshall.AgentRevocationFixture.setup() end)
    owner = fixture.owner
    vm = fixture.vm
    owned_cleanup(peers, vm, [owner, fixture.member])
    thread = fixture.thread

    turn = Marshall.AgentRevocationFixture.submit!(fixture)
    %{owner: owner, vm: vm, thread: thread, turn: turn}
  end

  @spec skill_fixture([pid()]) :: %{
          owner: Marshall.Accounts.User.t(),
          thread: Marshall.Threads.Thread.t()
        }
  defp skill_fixture(peers) do
    {:ok, %{owner: owner, vm: vm}} =
      Ledger.transaction(fn ->
        Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
      end)

    owned_cleanup(peers, vm, [owner])

    {:ok, thread} =
      Ledger.transaction(fn ->
        thread =
          Ledger.create!(Marshall.Threads.Thread, :open, %{
            creator_id: owner.id,
            objective: "Review the project",
            mode: :medium,
            machine_spec: request(),
            idempotency_key: Ash.UUID.generate(),
            machine_key: Ash.UUID.generate()
          })

        Ledger.update!(thread, :bind_machine, %{machine_id: vm.id, status: :ready})
      end)

    %{owner: owner, thread: thread}
  end

  @spec owned_cleanup([pid()], VirtualMachine.t(), [Marshall.Accounts.User.t()]) :: :ok
  defp owned_cleanup(peers, vm, users) do
    on_exit(fn ->
      Enum.each(peers, &stop_peer/1)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Recovery.cleanup!(vm.id, vm.host_id, users)
      end)
    end)
  end

  @spec question_call() :: map()
  defp question_call do
    %{
      id: "question-call",
      arguments: %{
        "questions" => [
          %{
            "id" => "approach",
            "header" => "Approach",
            "question" => "Which approach?",
            "options" => [
              %{"label" => "First", "description" => "Use the first approach."},
              %{"label" => "Second", "description" => "Use the second approach."}
            ]
          }
        ]
      }
    }
  end

  @spec compaction_request() :: map()
  defp compaction_request do
    %{
      "model" => "recovery-test-model",
      "input" => [
        %{"role" => "system", "content" => "canonical platform instructions"},
        %{"role" => "user", "content" => "old objective"},
        %{"role" => "assistant", "content" => "old result"},
        %{"role" => "user", "content" => "continue"}
      ],
      "tools" => [%{"name" => "read_file"}],
      "store" => false,
      "stream" => true
    }
  end

  @spec skill_result(String.t(), String.t(), String.t()) :: map()
  defp skill_result(operation_id, machine_id, machine_key) do
    path = "/var/lib/overalls/skills/" <> operation_id <> "/revision"

    %{
      "version" => 1,
      "operation_id" => operation_id,
      "status" => "installed",
      "full_commit" => String.duplicate("a", 40),
      "content_digest" => String.duplicate("b", 64),
      "path" => path,
      "skill_file" => %{
        "path" => path <> "/SKILL.md",
        "digest" => String.duplicate("c", 64),
        "bytes" => 100,
        "header" => "---\nname: review\ndescription: Review project changes\n---\n"
      },
      "machine_id" => machine_id,
      "machine_key" => machine_key
    }
  end
end
