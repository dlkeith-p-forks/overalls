defmodule Marshall.Agents.CompactionModelCallsTest do
  use Marshall.DataCase, async: false

  import Marshall.ComputeFixtures

  alias Marshall.Agents

  alias Marshall.Agents.{
    ContextCheckpoint,
    Event,
    Loop,
    ModelCall,
    ModelCalls,
    Prompt,
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
    {:ok, vm} = Compute.provision(request(%{profile: :standard}), actor: actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)

    outcome = %{
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
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(outcome))

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

  test "automatic compaction installs once, resumes inference and preserves a queued prompt", c do
    turn = start_turn(c)

    {:ok, %{turn_id: future_id}} =
      Agents.submit_prompt(
        %{
          thread_id: c.thread.id,
          prompt: "Future user request",
          request_key: Ash.UUID.generate()
        },
        actor: c.actor
      )

    append_history(c.thread.id, turn.id, 200)
    original_ids = Ledger.read!(Event, turn_id: turn.id) |> Enum.map(& &1.id)

    assert {:ok, %{purpose: :summary} = call} = ModelCalls.queue(turn.id, "test-model")
    refute Jason.encode!(call.request) =~ "Future user request"
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)
    assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)
    response = summary("Completed earlier checks; continue with the current objective.")
    assert {:ok, _} = ModelCalls.complete(c.token, call.id, work.claim_id, response)
    assert {:ok, _} = ModelCalls.complete(c.token, call.id, work.claim_id, response)

    assert [%{generation: 1, state: %{"kind" => "summary"}}] =
             Ledger.read!(ContextCheckpoint, thread_id: c.thread.id)

    assert [%{status: :running}] = Ledger.read!(Turn, id: turn.id)
    assert Enum.all?(original_ids, fn id -> Ledger.read!(Event, id: id) != [] end)

    assert {:ok, %{purpose: :inference, iteration: 2} = next} =
             ModelCalls.queue(turn.id, "test-model")

    assert Enum.count(next.request["input"], &(&1["content"] == "Current user request")) == 1
    refute Jason.encode!(next.request) =~ "Future user request"
    assert {:ok, %{call: next_work}} = ModelCalls.claim(c.token)

    assert {:ok, _} =
             ModelCalls.complete(c.token, next.id, next_work.claim_id, summary("Finished."))

    assert {:ok, %{id: ^future_id} = future} = TurnCoordinator.claim_next()
    prepare_context(c, future)
    assert {:ok, future_call} = ModelCalls.queue(future.id, "test-model")

    assert Enum.count(future_call.request["input"], &(&1["content"] == "Future user request")) ==
             1
  end

  test "manual compaction uses a maintenance turn with no fabricated user prompt", c do
    original = start_turn(c)
    append_history(c.thread.id, original.id, 4)
    assert {:ok, _} = TurnCoordinator.finish(original.id, :completed, "Original result.")

    assert {:ok, %{turn_id: id}} =
             Prompt.maintenance(c.thread.id, :compact_context, %{},
               actor: c.actor,
               request_key: Ash.UUID.generate()
             )

    assert {:ok, %{id: ^id} = turn} = TurnCoordinator.claim_next()
    prepare_context(c, turn)
    assert [] = Ledger.read!(Event, turn_id: id, kind: :prompt)
    assert {:ok, %{purpose: :summary} = call} = ModelCalls.queue(id, "test-model")
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)

    assert {:ok, _} =
             ModelCalls.complete(
               c.token,
               call.id,
               work.claim_id,
               summary("Original work finished.")
             )

    assert [%{status: :completed, prompt: nil}] = Ledger.read!(Turn, id: id)
    assert [] = Ledger.read!(Event, turn_id: id, kind: :prompt)
    assert [_] = Ledger.read!(ContextCheckpoint, turn_id: id)
  end

  test "definite provider context refusal compacts before a fresh inference attempt", c do
    turn = start_turn(c)
    append_history(c.thread.id, turn.id, 3)
    assert {:ok, %{purpose: :inference} = call} = ModelCalls.queue(turn.id, "test-model")
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)

    assert {:ok, _} =
             ModelCalls.complete(c.token, call.id, work.claim_id, %{
               "error" => "context_length_exceeded"
             })

    assert [%{status: :failed}] = Ledger.read!(ModelCall, id: call.id)
    assert [%{status: :running}] = Ledger.read!(Turn, id: turn.id)
    assert {:ok, %{purpose: :summary} = compact} = ModelCalls.queue(turn.id, "test-model")
    refute compact.id == call.id
    assert {:ok, %{call: compact_work}} = ModelCalls.claim(c.token)

    assert {:ok, _} =
             ModelCalls.complete(
               c.token,
               compact.id,
               compact_work.claim_id,
               summary("Earlier work recorded.")
             )

    assert {:ok, %{purpose: :inference} = resumed} = ModelCalls.queue(turn.id, "test-model")
    refute resumed.id in [call.id, compact.id]
  end

  test "ambiguous claimed compaction is never replayed and installs no checkpoint", c do
    turn = start_turn(c)
    append_history(c.thread.id, turn.id, 200)
    assert {:ok, %{purpose: :summary} = call} = ModelCalls.queue(turn.id, "test-model")
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)
    [claimed] = Ledger.read!(ModelCall, id: call.id)
    Ledger.update!(claimed, :transition, %{claimed_at: DateTime.add(Ledger.now(), -601, :second)})
    assert :ok = Loop.tick()
    assert [%{status: :uncertain}] = Ledger.read!(ModelCall, id: call.id)
    assert [] = Ledger.read!(ContextCheckpoint, thread_id: c.thread.id)
    assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)

    assert {:error, _} =
             ModelCalls.complete(c.token, call.id, work.claim_id, summary("Late summary."))

    assert [_] = Ledger.read!(ModelCall, turn_id: turn.id)
  end

  test "incomplete compaction response leaves transcript and checkpoint untouched", c do
    turn = start_turn(c)
    append_history(c.thread.id, turn.id, 200)
    assert {:ok, call} = ModelCalls.queue(turn.id, "test-model")
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)
    response = Map.put(summary("Partial."), "status", "incomplete")
    assert {:ok, _} = ModelCalls.complete(c.token, call.id, work.claim_id, response)
    assert [] = Ledger.read!(ContextCheckpoint, thread_id: c.thread.id)
    assert length(Ledger.read!(Event, turn_id: turn.id, kind: :assistant)) == 200
    assert [%{status: :failed}] = Ledger.read!(Turn, id: turn.id)
  end

  @spec start_turn(map()) :: Turn.t()
  defp start_turn(c) do
    {:ok, %{turn_id: id}} =
      Agents.submit_prompt(
        %{
          thread_id: c.thread.id,
          prompt: "Current user request",
          request_key: Ash.UUID.generate()
        },
        actor: c.actor
      )

    {:ok, %{id: ^id} = turn} = TurnCoordinator.claim_next()
    prepare_context(c, turn)
    turn
  end

  @spec prepare_context(map(), Turn.t()) :: Marshall.Agents.ContextSnapshot.t()
  defp prepare_context(c, turn),
    do: Marshall.AgentContextFixtures.context_fixture(turn, c.vm, c.actor)

  @spec append_history(String.t(), String.t(), pos_integer()) :: :ok
  defp append_history(thread_id, turn_id, count) do
    {:ok, :ok} =
      Ledger.transaction(fn ->
        thread = Ledger.lock!(Thread, thread_id)

        for index <- 0..(count - 1) do
          Ledger.create!(Event, :append, %{
            thread_id: thread.id,
            turn_id: turn_id,
            sequence: thread.next_event_sequence + index,
            kind: :assistant,
            body: %{
              "text" => "Inspected item #{index}. " <> String.duplicate("Retained details. ", 8)
            }
          })
        end

        Ledger.update!(thread, :advance, %{
          next_event_sequence: thread.next_event_sequence + count
        })

        :ok
      end)

    :ok
  end

  @spec summary(String.t()) :: map()
  defp summary(text),
    do: %{
      "status" => "completed",
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => text}]}
      ]
    }
end
