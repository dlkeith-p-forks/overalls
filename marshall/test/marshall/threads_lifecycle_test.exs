defmodule Marshall.ThreadsLifecycleTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures

  alias Marshall.Agents.{Planning, PlanningQuestion}
  alias Marshall.Agents.Thread, as: AgentThread
  alias Marshall.Agents.Turn, as: AgentTurn
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes, VirtualMachine}
  alias Marshall.Threads
  alias Marshall.Threads.{ArchiveWorker, ProvisionWorker, Thread}

  @type arguments :: %{
          objective: String.t(),
          mode: :medium,
          machine_spec: map(),
          idempotency_key: String.t()
        }

  test "create replay retains its original identity through archive and reopen" do
    actor = user()
    arguments = arguments()
    assert {:ok, thread} = Threads.create_thread(arguments, actor: actor)
    assert {:ok, archived} = Threads.archive_thread(%{thread_id: thread.id}, actor: actor)
    assert archived.status == :archived

    assert {:ok, archived_replay} = Threads.create_thread(arguments, actor: actor)
    assert archived_replay.id == thread.id
    assert archived_replay.status == :archived

    assert {:ok, reopened} = Threads.reopen_thread(%{thread_id: thread.id}, actor: actor)
    assert reopened.idempotency_key == arguments.idempotency_key
    refute reopened.machine_key == archived.machine_key
    assert {:ok, reopened_replay} = Threads.create_thread(arguments, actor: actor)
    assert reopened_replay.id == thread.id
    assert reopened_replay.machine_key == reopened.machine_key
    assert [%Thread{id: id}] = Ledger.history!(Thread, idempotency_key: arguments.idempotency_key)
    assert id == thread.id
  end

  test "archiving a pending machine retains its binding until physical deletion" do
    host_fixture()
    actor = user()
    assert {:ok, thread} = Threads.create_thread(arguments(), actor: actor)
    assert {:snooze, _} = provision(thread)
    bound = current(thread)
    assert bound.status == :provisioning
    assert is_binary(bound.machine_id)

    assert [%VirtualMachine{observed_state: :pending} = vm] =
             Ledger.history!(VirtualMachine, id: bound.machine_id)

    assert {:ok, deleting} = Threads.archive_thread(%{thread_id: thread.id}, actor: actor)
    assert deleting.status == :deleting
    assert deleting.machine_id == vm.id
    assert is_nil(deleting.archived_at)
    assert [%Operation{} = operation] = Ledger.read!(Operation, vm_id: vm.id, kind: :delete)

    _ =
      ArchiveWorker.perform(%Oban.Job{
        args: %{"thread_id" => thread.id, "machine_key" => current(thread).machine_key}
      })

    assert current(thread).status == :deleting
    assert {:ok, replay} = Threads.delete_thread(%{thread_id: thread.id}, actor: actor)
    assert replay.status == :deleting
    assert [%Operation{id: operation_id}] = Ledger.read!(Operation, vm_id: vm.id, kind: :delete)
    assert operation_id == operation.id

    assert {:ok, _} = observe(vm, operation, :deleted)

    assert :ok =
             ArchiveWorker.perform(%Oban.Job{
               args: %{"thread_id" => thread.id, "machine_key" => current(thread).machine_key}
             })

    archived = current(thread)
    assert archived.status == :archived
    assert %DateTime{} = archived.archived_at
    assert archived.machine_id == vm.id
    assert :ok = provision(thread)
    assert current(thread).status == :archived
  end

  test "archiving a thread cancels its pending planning question" do
    host_fixture()
    actor = user()
    assert {:ok, thread} = Threads.create_thread(arguments(), actor: actor)
    assert {:snooze, _} = provision(thread)
    bound = current(thread)
    assert [%VirtualMachine{} = vm] = Ledger.history!(VirtualMachine, id: bound.machine_id)
    assert [%Operation{} = operation] = Ledger.read!(Operation, vm_id: vm.id, kind: :provision)
    assert {:ok, _} = observe(vm, operation, :running)
    assert :ok = provision(bound)

    ready = current(thread)
    assert ready.status == :ready
    assert is_binary(ready.agent_thread_id)

    {:ok, question} =
      Ledger.transaction(fn ->
        agent_thread = Ledger.lock!(AgentThread, ready.agent_thread_id)

        turn =
          Ledger.create!(AgentTurn, :enqueue, %{
            thread_id: agent_thread.id,
            actor_id: actor.id,
            request_key: Ash.UUID.generate(),
            ordinal: 2,
            prompt: "Choose the implementation approach.",
            collaboration_mode: :plan
          })

        turn = Ledger.update!(turn, :transition, %{status: :running, started_at: Ledger.now()})
        agent_thread = Ledger.update!(agent_thread, :set_context, %{collaboration_mode: :plan})
        agent_thread = Ledger.update!(agent_thread, :advance, %{active_turn_id: turn.id})
        Planning.request_questions_locked!(agent_thread, turn, planning_call())
      end)

    assert [%PlanningQuestion{status: :pending}] = Ledger.read!(PlanningQuestion, id: question.id)
    assert {:ok, deleting} = Threads.archive_thread(%{thread_id: ready.id}, actor: actor)
    assert deleting.status == :deleting

    assert [%PlanningQuestion{status: :cancelled, cancellation_reason: :archived}] =
             Ledger.read!(PlanningQuestion, id: question.id)
  end

  test "an existing delete intent is not proof of physical deletion" do
    host_fixture()
    actor = user()
    assert {:ok, thread} = Threads.create_thread(arguments(), actor: actor)
    assert {:snooze, _} = provision(thread)
    bound = current(thread)

    assert {:ok, _} =
             Marshall.Compute.lifecycle(
               %{vm_id: bound.machine_id, kind: :delete, idempotency_key: Ash.UUID.generate()},
               actor: actor
             )

    assert {:ok, deleting} = Threads.archive_thread(%{thread_id: thread.id}, actor: actor)
    assert deleting.status == :deleting
    assert is_nil(deleting.archived_at)

    assert [%{desired_state: :deleted, archived_at: nil}] =
             Ledger.history!(VirtualMachine, id: bound.machine_id)
  end

  test "each reopened machine gets one initial objective and old jobs cannot change its binding" do
    host_fixture()
    actor = user()
    arguments = arguments()
    assert {:ok, first} = Threads.create_thread(arguments, actor: actor)

    {last, machine_ids} =
      Enum.reduce(1..3, {first, []}, fn generation, {thread, machine_ids} ->
        assert {:snooze, _} = provision(thread)
        bound = current(thread)
        assert [%VirtualMachine{} = vm] = Ledger.history!(VirtualMachine, id: bound.machine_id)

        assert [%Operation{} = provision_operation] =
                 Ledger.read!(Operation, vm_id: vm.id, kind: :provision)

        assert {:ok, _} = observe(vm, provision_operation, :running)
        assert :ok = provision(bound)
        ready = current(thread)
        assert ready.status == :ready
        assert :ok = provision(bound)

        assert [%{prompt: objective}] =
                 Ledger.read!(Marshall.Agents.Turn, thread_id: ready.agent_thread_id)

        assert objective == arguments.objective
        assert {:ok, replay} = Threads.create_thread(arguments, actor: actor)
        assert replay.id == first.id

        if generation < 3 do
          assert {:ok, deleting} = Threads.archive_thread(%{thread_id: ready.id}, actor: actor)
          assert deleting.status == :deleting

          assert [%Operation{} = delete_operation] =
                   Ledger.read!(Operation, vm_id: vm.id, kind: :delete)

          assert {:ok, _} = observe(vm, delete_operation, :deleted, 2)

          assert :ok =
                   ArchiveWorker.perform(%Oban.Job{
                     args: %{"thread_id" => ready.id, "machine_key" => current(ready).machine_key}
                   })

          assert {:ok, reopened} = Threads.reopen_thread(%{thread_id: ready.id}, actor: actor)
          assert :ok = provision(ready)
          assert current(reopened).status == :pending
          assert current(reopened).machine_key == reopened.machine_key
          {reopened, [vm.id | machine_ids]}
        else
          {ready, [vm.id | machine_ids]}
        end
      end)

    assert length(Enum.uniq(machine_ids)) == 3
    assert last.idempotency_key == arguments.idempotency_key
    assert last.status == :ready
    assert [%{desired_state: :running}] = Ledger.history!(VirtualMachine, id: last.machine_id)
  end

  test "retry waits for failed machine cleanup and then rotates only the machine key" do
    host_fixture()
    actor = user()
    assert {:ok, thread} = Threads.create_thread(arguments(), actor: actor)
    assert {:snooze, _} = provision(thread)
    bound = current(thread)

    failed =
      Marshall.ThreadStateFixture.failed!(bound, :agent_unavailable)

    assert [%VirtualMachine{} = vm] = Ledger.history!(VirtualMachine, id: failed.machine_id)

    assert {:ok, delete_operation} =
             Marshall.Compute.lifecycle(
               %{vm_id: vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()},
               actor: actor
             )

    assert {:error, _} = Threads.retry_provisioning(%{thread_id: failed.id}, actor: actor)
    assert current(thread).machine_key == failed.machine_key
    assert {:ok, _} = observe(vm, delete_operation, :deleted)
    assert {:ok, retrying} = Threads.retry_provisioning(%{thread_id: failed.id}, actor: actor)
    assert retrying.status == :pending
    assert is_nil(retrying.machine_id)
    refute retrying.machine_key == failed.machine_key
    assert retrying.idempotency_key == failed.idempotency_key
    assert :ok = provision(failed)
    assert current(thread).machine_key == retrying.machine_key
    assert current(thread).status == :pending
  end

  @spec arguments() :: arguments()
  defp arguments do
    %{
      objective: "Inspect the deployment",
      mode: :medium,
      machine_spec: request(),
      idempotency_key: Ash.UUID.generate()
    }
  end

  @spec planning_call() :: map()
  defp planning_call do
    %{
      id: "archive-question",
      arguments: %{
        "questions" => [
          %{
            "id" => "approach",
            "header" => "Approach",
            "question" => "Which approach should the plan use?",
            "options" => [
              %{"label" => "First", "description" => "Keep the current interface."},
              %{"label" => "Second", "description" => "Add a new interface."}
            ]
          }
        ]
      }
    }
  end

  @spec current(Thread.t()) :: Thread.t()
  defp current(thread) do
    [current] = Ledger.history!(Thread, id: thread.id)
    current
  end

  @spec provision(Thread.t()) :: :ok | {:error, term()} | {:snooze, pos_integer()}
  defp provision(thread) do
    ProvisionWorker.perform(%Oban.Job{
      args: %{"thread_id" => thread.id, "machine_key" => thread.machine_key}
    })
  end

  @spec observe(VirtualMachine.t(), Operation.t(), :running | :deleted, pos_integer()) ::
          {:ok, term()} | {:error, term()}
  defp observe(vm, operation, state, sequence \\ 1) do
    {:ok, outcome} =
      OverallsProtocol.Execution.outcome(
        OverallsProtocol.Execution.encode_outcome(%{
          id: Ash.UUID.generate(),
          vm_id: vm.id,
          placement_id: operation.placement_id,
          execution_epoch: operation.execution_epoch,
          operation_id: operation.id,
          generation: operation.generation,
          sequence: sequence,
          state: state,
          compute_empty: state == :deleted,
          disk_present: state != :deleted,
          cleanup_complete: state == :deleted,
          reason: :none
        })
      )

    Ledger.transaction(fn ->
      Ledger.lock!(Host, vm.host_id)
      Outcomes.ingest_locked!(vm.host_id, [outcome])
    end)
  end
end
