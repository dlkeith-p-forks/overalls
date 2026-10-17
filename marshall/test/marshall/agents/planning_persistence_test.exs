defmodule Marshall.Agents.PlanningPersistenceTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Agents.{Event, PlanProposal, Planning, PlanningQuestion, Root, Thread, Turn}
  alias Marshall.Compute
  alias Marshall.Compute.Ledger

  setup do
    host_fixture()
    actor = user()
    {:ok, vm} = Compute.provision(request(), actor: actor)
    [root] = Ledger.read!(Root, vm_id: vm.id)
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

    %{actor: actor, vm: vm, thread: thread, turn: turn}
  end

  test "questions survive projection reload and their original call replays once", c do
    assert {:ok, request} = request_questions(c)
    assert Planning.awaiting?(c.thread.id)
    assert %{id: id, status: :pending} = Planning.pending(c.thread.id)
    assert id == request.id
    assert {:ok, %{id: ^id}} = request_questions(c)
    assert [_] = Ledger.read!(Event, turn_id: c.turn.id, kind: :questions_requested)

    changed = put_in(call(), [:arguments, "questions", Access.at(0), "question"], "Changed?")

    assert {:error, :idempotency_conflict} =
             Ledger.transaction(fn ->
               thread = Ledger.lock!(Thread, c.thread.id)
               Planning.request_questions_locked!(thread, c.turn, changed)
             end)

    assert [%{questions: questions}] = Ledger.read!(PlanningQuestion, turn_id: c.turn.id)
    assert questions == call().arguments["questions"]
  end

  test "the first answer wins, retries are stable, and the tool result is appended once", c do
    {:ok, question} = request_questions(c)
    key = Ash.UUID.generate()
    parameters = %{question_id: question.id, answers: answers(), request_key: key}
    assert {:ok, %{status: :answered}} = Planning.answer(parameters, actor: c.actor)
    refute Planning.awaiting?(c.thread.id)
    assert {:ok, %{status: :answered}} = Planning.answer(parameters, actor: c.actor)

    assert {:error, :idempotency_conflict} =
             Planning.answer(%{parameters | answers: answers("Second")}, actor: c.actor)

    assert {:error, :already_answered} =
             Planning.answer(%{parameters | request_key: Ash.UUID.generate()}, actor: c.actor)

    assert [%{answers: persisted}] = Ledger.read!(PlanningQuestion, id: question.id)
    assert persisted == %{"approach" => %{"selected" => "First", "text" => ""}}
    assert [_] = Ledger.read!(Event, turn_id: c.turn.id, kind: :questions_answered)

    assert [%{body: %{"call_id" => "question-call", "result" => %{"answers" => ^persisted}}}] =
             Ledger.read!(Event, turn_id: c.turn.id, kind: :tool_result)

    assert [%{active_turn_id: active_id}] = Ledger.read!(Thread, id: c.thread.id)
    assert active_id == c.turn.id
  end

  test "current write authority is required, including on an otherwise valid replay", c do
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

    {:ok, question} = request_questions(c)
    parameters = %{question_id: question.id, answers: answers(), request_key: Ash.UUID.generate()}
    assert {:ok, _} = Planning.answer(parameters, actor: member)

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

    assert {:error, :forbidden} = Planning.answer(parameters, actor: member)
  end

  test "cancellation clears the durable barrier and rejects a late answer", c do
    {:ok, question} = request_questions(c)

    assert {:ok, :ok} =
             Ledger.transaction(fn ->
               Ledger.lock!(Turn, c.turn.id)
               Ledger.lock!(Thread, c.thread.id)
               Planning.cancel_pending_locked!(c.thread.id, :access_revoked)
             end)

    refute Planning.awaiting?(c.thread.id)

    assert [%{status: :cancelled, cancellation_reason: :access_revoked}] =
             Ledger.read!(PlanningQuestion, id: question.id)

    assert {:error, :stale_question} =
             Planning.answer(
               %{question_id: question.id, answers: answers(), request_key: Ash.UUID.generate()},
               actor: c.actor
             )
  end

  test "another writer cannot revive questions after the originating actor loses authority", c do
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

    {:ok, {thread, turn}} =
      Ledger.transaction(fn ->
        Ledger.update!(c.turn, :transition, %{status: :completed, finished_at: Ledger.now()})

        turn =
          Ledger.create!(Turn, :enqueue, %{
            thread_id: c.thread.id,
            actor_id: member.id,
            request_key: Ash.UUID.generate(),
            ordinal: 2,
            prompt: "Plan a change.",
            collaboration_mode: :plan
          })

        turn = Ledger.update!(turn, :transition, %{status: :running, started_at: Ledger.now()})
        thread = Ledger.update!(c.thread, :advance, %{active_turn_id: turn.id})
        {thread, turn}
      end)

    {:ok, question} = request_questions(%{c | thread: thread, turn: turn})

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

    assert {:error, :stale_question} =
             Planning.answer(
               %{
                 question_id: question.id,
                 answers: answers(),
                 request_key: Ash.UUID.generate()
               },
               actor: c.actor
             )

    assert [%{status: :cancelled, cancellation_reason: :access_revoked}] =
             Ledger.read!(PlanningQuestion, id: question.id)

    refute Planning.awaiting?(thread.id)
  end

  test "root mode and active ownership gate human questions", c do
    for {thread, turn} <- [
          {c.thread, %{c.turn | collaboration_mode: :work}},
          {%{c.thread | parent_thread_id: Ash.UUID.generate()}, c.turn},
          {%{c.thread | active_turn_id: nil}, c.turn},
          {c.thread, %{c.turn | status: :completed}}
        ] do
      assert {:error, :planning_not_allowed} =
               Ledger.transaction(fn ->
                 Ledger.lock!(Turn, c.turn.id)
                 Ledger.lock!(Thread, c.thread.id)
                 Planning.request_questions_locked!(thread, turn, call())
               end)
    end

    assert [] = Ledger.read!(PlanningQuestion, turn_id: c.turn.id)
  end

  test "only completed plans are retained and implementation binds one exact Work turn", c do
    text = "<proposed_plan>\n# Plan\n\nImplement and verify the change.\n</proposed_plan>"

    assert {:ok, nil} =
             Ledger.transaction(fn ->
               thread = Ledger.lock!(Thread, c.thread.id)
               Planning.record_proposal_locked!(thread, c.turn, text)
             end)

    {:ok, proposal} =
      Ledger.transaction(fn ->
        turn = Ledger.lock!(Turn, c.turn.id)
        thread = Ledger.lock!(Thread, c.thread.id)
        turn = Ledger.update!(turn, :transition, %{status: :completed, finished_at: Ledger.now()})
        thread = Ledger.update!(thread, :advance, %{active_turn_id: nil})
        Planning.record_proposal_locked!(thread, turn, text)
      end)

    assert proposal.text == "# Plan\n\nImplement and verify the change."
    assert Planning.latest_proposal(c.thread.id).id == proposal.id
    key = Ash.UUID.generate()

    assert {:error, :injected_failure} =
             Ledger.transaction(fn ->
               thread = Ledger.lock!(Thread, c.thread.id)

               Planning.implementation_locked!(thread, proposal.id, c.actor, key, fn _, _ ->
                 Ledger.update!(thread, :set_context, %{collaboration_mode: :work})
                 Ledger.rollback(:injected_failure)
               end)
             end)

    assert [%{collaboration_mode: :plan}] = Ledger.read!(Thread, id: c.thread.id)
    assert [%{implementing_turn_id: nil}] = Ledger.read!(PlanProposal, id: proposal.id)

    admit = fn retained, prompt ->
      assert retained.id == proposal.id
      assert prompt == "Implement the following plan:\n\n" <> proposal.text
      [current_thread] = Ledger.read!(Thread, id: c.thread.id)
      Ledger.update!(current_thread, :set_context, %{collaboration_mode: :work})

      turn =
        Ledger.create!(Turn, :enqueue, %{
          thread_id: c.thread.id,
          actor_id: c.actor.id,
          request_key: key,
          ordinal: 2,
          prompt: prompt,
          collaboration_mode: :work
        })

      %{turn_id: turn.id, status: turn.status}
    end

    assert {:ok, %{turn_id: implementing_id}} =
             Ledger.transaction(fn ->
               thread = Ledger.lock!(Thread, c.thread.id)
               Planning.implementation_locked!(thread, proposal.id, c.actor, key, admit)
             end)

    assert {:ok, %{turn_id: ^implementing_id}} =
             Ledger.transaction(fn ->
               thread = Ledger.lock!(Thread, c.thread.id)

               Planning.implementation_locked!(thread, proposal.id, c.actor, key, fn _, _ ->
                 flunk("a replay must not enqueue another turn")
               end)
             end)

    assert [%{implementing_turn_id: ^implementing_id}] =
             Ledger.read!(PlanProposal, id: proposal.id)

    assert [%{collaboration_mode: :work, thread_id: thread_id}] =
             Ledger.read!(Turn, id: implementing_id)

    assert thread_id == c.thread.id
  end

  @spec request_questions(map()) :: {:ok, PlanningQuestion.t()} | {:error, term()}
  defp request_questions(c) do
    Ledger.transaction(fn ->
      turn = Ledger.lock!(Turn, c.turn.id)
      thread = Ledger.lock!(Thread, c.thread.id)
      Planning.request_questions_locked!(thread, turn, call())
    end)
  end

  @spec call() :: map()
  defp call do
    %{
      id: "question-call",
      arguments: %{
        "questions" => [
          %{
            "id" => "approach",
            "header" => "Approach",
            "question" => "Which approach should the plan use?",
            "options" => [
              %{"label" => "First", "description" => "Keep the existing interface."},
              %{"label" => "Second", "description" => "Add a new interface."}
            ]
          }
        ]
      }
    }
  end

  @spec answers(String.t()) :: map()
  defp answers(choice \\ "First"), do: %{"approach" => %{"selected" => choice}}
end
