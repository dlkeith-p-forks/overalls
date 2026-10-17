defmodule Marshall.Agents.PlanningLoopTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  import Marshall.AgentContextFixtures
  alias Marshall.Agents

  alias Marshall.Agents.{
    Event,
    Loop,
    ModelCall,
    ModelCalls,
    Planning,
    PlanningQuestion,
    Root,
    Thread,
    Turn,
    TurnCoordinator
  }

  alias Marshall.Compute
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes}
  alias Marshall.Inference.Credentials

  setup do
    host_fixture()
    actor = user()
    {:ok, vm} = Compute.provision(request(%{profile: :oss}), actor: actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)

    event = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: 1,
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    {:ok, parsed} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    {:ok, _} =
      Ledger.transaction(fn ->
        Ledger.lock!(Host, vm.host_id)
        Outcomes.ingest_locked!(vm.host_id, [parsed])
      end)

    [root] = Ledger.read!(Root, vm_id: vm.id)
    [thread] = Ledger.read!(Thread, root_id: root.id)
    {:ok, issued} = Credentials.rotate(vm.host_id, 3600)
    %{actor: actor, vm: vm, thread: thread, token: issued.id <> "." <> issued.secret}
  end

  test "provider questions stop model and queued turns until one durable answer resumes", c do
    turn = start_plan(c)
    assert {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")
    assert Enum.any?(call.request["tools"], &(&1["name"] == "request_user_input"))
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)
    assert {:ok, _} = ModelCalls.complete(c.token, call.id, work.claim_id, question_response())

    question = Planning.pending(c.thread.id)
    assert question.turn_id == turn.id

    assert {:ok, %{turn_id: future_id}} =
             Agents.submit_prompt(
               %{
                 thread_id: c.thread.id,
                 prompt: "Later task",
                 request_key: Ash.UUID.generate()
               },
               actor: c.actor
             )

    for _ <- 1..3 do
      assert :ok = Loop.tick()
      assert {:ok, nil} = TurnCoordinator.claim_next()
      assert {:error, :waiting_for_answers} = ModelCalls.queue(turn.id, "gpt-6-sol")
    end

    assert [_] = Ledger.read!(ModelCall, turn_id: turn.id)
    assert [%{status: :queued}] = Ledger.read!(Turn, id: future_id)

    parameters = %{
      question_id: question.id,
      request_key: Ash.UUID.generate(),
      answers: %{"storage" => %{"selected" => "Database"}}
    }

    assert {:ok, _} = Planning.answer(parameters, actor: c.actor)
    assert {:ok, _} = Planning.answer(parameters, actor: c.actor)
    assert :ok = Loop.tick()
    assert :ok = Loop.tick()
    assert [next] = Ledger.read!(ModelCall, turn_id: turn.id, iteration: 2)
    assert next.status == :queued
    assert [%{status: :queued}] = Ledger.read!(Turn, id: future_id)
    refute Enum.any?(next.request["input"], &(&1["content"] == "Later task"))

    assert Enum.count(next.request["input"], fn item ->
             item["type"] == "function_call_output" and item["call_id"] == "question-1" and
               Jason.decode!(item["output"])["answers"]["storage"]["selected"] == "Database"
           end) == 1

    assert {:ok, %{call: next_work}} = ModelCalls.claim(c.token)

    assert {:ok, _} =
             ModelCalls.complete(
               c.token,
               next.id,
               next_work.claim_id,
               assistant_response(
                 "<proposed_plan>\nUse the existing database and verify recovery.\n</proposed_plan>"
               )
             )

    assert %{turn_id: proposal_turn} = Planning.latest_proposal(c.thread.id)
    assert proposal_turn == turn.id
    assert [%{status: :completed}] = Ledger.read!(Turn, id: turn.id)
    assert [_] = Ledger.read!(Event, turn_id: turn.id, kind: :plan_proposed)
  end

  test "completed proposal implementation uses the same machine and preserves reasoning", c do
    {:ok, _} = Ledger.transaction(fn -> Ledger.update!(c.thread, :set_mode, %{mode: :high}) end)
    turn = start_plan(c)
    {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol", :high)
    {:ok, %{call: work}} = ModelCalls.claim(c.token)

    assert {:ok, _} =
             ModelCalls.complete(
               c.token,
               call.id,
               work.claim_id,
               assistant_response(
                 "<proposed_plan>\n# Delivery\n\nImplement the agreed interface.\n</proposed_plan>"
               )
             )

    proposal = Planning.latest_proposal(c.thread.id)
    key = Ash.UUID.generate()

    implement = fn ->
      Ledger.transaction(fn ->
        thread = Ledger.lock!(Thread, c.thread.id)

        Planning.implementation_locked!(thread, proposal.id, c.actor, key, fn _, prompt ->
          case Agents.submit_prompt(
                 %{
                   thread_id: thread.id,
                   prompt: prompt,
                   request_key: key,
                   collaboration_mode: :work
                 },
                 actor: c.actor
               ) do
            {:ok, result} -> result
            {:error, _} -> Ledger.rollback(:invalid_implementation)
          end
        end)
      end)
    end

    assert {:ok, %{turn_id: work_id}} = implement.()
    assert {:ok, %{turn_id: ^work_id}} = implement.()

    assert [%{collaboration_mode: :work, mode: :high, thread_id: same_thread}] =
             Ledger.read!(Turn, id: work_id)

    assert same_thread == c.thread.id

    assert [%{collaboration_mode: :work, root_id: root_id}] =
             Ledger.read!(Thread, id: same_thread)

    assert [%{vm_id: vm_id}] = Ledger.read!(Root, id: root_id)
    assert vm_id == c.vm.id
    assert [%{kind: :prompt}] = Ledger.read!(Event, turn_id: work_id, kind: :prompt)
  end

  test "revocation terminates a pending planning turn and cancels its unanswered request", c do
    member = user()

    {:ok, _} =
      Marshall.Access.set_access(
        %{
          vm_id: c.vm.id,
          email: to_string(member.email),
          role: :operator,
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.actor
      )

    turn = start_plan(%{c | actor: member}, c.actor)
    {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")
    {:ok, %{call: work}} = ModelCalls.claim(c.token)
    {:ok, _} = ModelCalls.complete(c.token, call.id, work.claim_id, question_response())
    question = Planning.pending(c.thread.id)

    {:ok, _} =
      Marshall.Access.set_access(
        %{
          vm_id: c.vm.id,
          email: to_string(member.email),
          role: :revoked,
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.actor
      )

    assert :ok = Loop.tick()
    assert [%{status: :failed, failure_reason: :access_revoked}] = Ledger.read!(Turn, id: turn.id)

    assert [%{status: :cancelled, cancellation_reason: :access_revoked}] =
             Ledger.read!(PlanningQuestion, id: question.id)

    refute Planning.awaiting?(c.thread.id)
    assert [_] = Ledger.read!(ModelCall, turn_id: turn.id)
  end

  test "child agents inherit planning settings without human question authority", c do
    turn = start_plan(c)
    {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")
    {:ok, %{call: work}} = ModelCalls.claim(c.token)

    {:ok, _} =
      ModelCalls.complete(c.token, call.id, work.claim_id, %{
        "status" => "completed",
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "child-plan",
            "name" => "spawn_child_agent",
            "arguments" =>
              Jason.encode!(%{"title" => "Investigate", "prompt" => "Inspect the interface."})
          }
        ]
      })

    [child] = Ledger.read!(Thread, parent_thread_id: c.thread.id)
    assert child.collaboration_mode == :plan
    assert child.working_directory == "/workspace"
    assert {:ok, child_turn} = TurnCoordinator.claim_next()
    assert child_turn.thread_id == child.id
    assert child_turn.collaboration_mode == :plan
    context_fixture(child_turn, c.vm, c.actor)
    assert {:ok, child_call} = ModelCalls.queue(child_turn.id, "gpt-6-sol")
    refute Enum.any?(child_call.request["tools"], &(&1["name"] == "request_user_input"))
    assert {:ok, %{call: child_work}} = ModelCalls.claim(c.token)

    assert {:ok, _} =
             ModelCalls.complete(c.token, child_call.id, child_work.claim_id, question_response())

    assert [%{status: :failed, failure_reason: :capability_denied}] =
             Ledger.read!(Turn, id: child_turn.id)

    assert [] = Ledger.read!(PlanningQuestion, turn_id: child_turn.id)
  end

  @spec start_plan(map(), Marshall.Accounts.User.t() | nil) :: Turn.t()
  defp start_plan(c, owner \\ nil) do
    assert {:ok, %{turn_id: id}} =
             Agents.submit_prompt(
               %{
                 thread_id: c.thread.id,
                 prompt: "Plan the requested change.",
                 collaboration_mode: :plan,
                 request_key: Ash.UUID.generate()
               },
               actor: c.actor
             )

    assert {:ok, %{id: ^id} = turn} = TurnCoordinator.claim_next()
    context_fixture(turn, c.vm, owner || c.actor)
    turn
  end

  @spec question_response() :: map()
  defp question_response do
    %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "function_call",
          "call_id" => "question-1",
          "name" => "request_user_input",
          "arguments" =>
            Jason.encode!(%{
              "questions" => [
                %{
                  "id" => "storage",
                  "header" => "Storage",
                  "question" => "Which store should the plan use?",
                  "options" => [
                    %{"label" => "Database", "description" => "Share records between workers."},
                    %{"label" => "Files", "description" => "Keep local records."}
                  ]
                }
              ]
            })
        }
      ]
    }
  end

  @spec assistant_response(String.t()) :: map()
  defp assistant_response(text) do
    %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ]
    }
  end
end
