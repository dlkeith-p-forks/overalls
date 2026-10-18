defmodule Marshall.Agents.ModelCallsTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Agents

  alias Marshall.Agents.{
    AuditEvent,
    Command,
    Context,
    ContextSnapshot,
    Conversation,
    Event,
    Executor,
    ExecutorSession,
    Loop,
    ModelCall,
    ModelCalls,
    Root,
    Thread,
    Turn,
    TurnCoordinator,
    WebSearch,
    SearchUsage
  }

  alias Marshall.Compute
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes}
  alias Marshall.Inference.Credentials

  setup context do
    host_fixture()
    actor = user()

    {:ok, vm} =
      Compute.provision(request(%{profile: Map.get(context, :profile, :standard)}),
        actor: actor
      )

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

    {:ok, account} =
      Ledger.transaction(fn -> Marshall.Accounts.GuestAccounts.ensure!(actor.id) end)

    binding = %{
      "host_id" => vm.host_id,
      "vm_id" => vm.id,
      "placement_id" => vm.current_placement_id,
      "execution_epoch" => vm.execution_epoch
    }

    {:ok, _executor} = ExecutorSession.register(binding, nil, ["context-v1"])

    %{
      actor: actor,
      vm: vm,
      thread: thread,
      account: account,
      token: issued.id <> "." <> issued.secret
    }
  end

  test "a model call is claimed once and atomically finishes its turn", c do
    turn = start_turn(c)
    assert {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")
    assert call.iteration == 1
    assert {:error, :already_queued} = ModelCalls.queue(turn.id, "gpt-6-sol")
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)
    assert work.id == call.id
    assert work.binding.vm_id == c.vm.id
    assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)

    response = %{"choices" => [%{"message" => %{"content" => "Hello"}}]}

    assert {:ok, %{acknowledged: id}} =
             ModelCalls.complete(c.token, call.id, work.claim_id, response)

    assert id == call.id

    assert {:ok, %{acknowledged: ^id}} =
             ModelCalls.complete(c.token, call.id, work.claim_id, response)

    assert [%{status: :completed}] = Ledger.read!(Turn, id: turn.id)
    assert [%{status: :completed}] = Ledger.read!(ModelCall, id: call.id)

    assert [%{kind: :assistant, body: %{"text" => "Hello"}}] =
             Ledger.read!(Event, turn_id: turn.id, kind: :assistant)

    assert [%{kind: :model_dispatched}] =
             Ledger.read!(AuditEvent, target_id: call.id, kind: :model_dispatched)

    assert [%{kind: :model_finished}] =
             Ledger.read!(AuditEvent, target_id: call.id, kind: :model_finished)

    assert {:error, _} = ModelCalls.complete(c.token, call.id, Ash.UUID.generate(), response)
  end

  test "repeated host polls never claim the same model attempt twice", c do
    Hegel.check(
      fn ->
        extra_polls = draw("extra_polls", integer(1..8))
        turn = start_turn(c)
        assert {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")
        assert {:ok, %{call: %{id: id, claim_id: claim_id}}} = ModelCalls.claim(c.token)
        assert id == call.id

        for _ <- 1..extra_polls do
          assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)
        end

        assert {:ok, _} =
                 ModelCalls.complete(c.token, id, claim_id, %{
                   "choices" => [%{"message" => %{"content" => "done"}}]
                 })
      end,
      test_cases: 100
    )
  end

  test "a later queued prompt cannot enter the active turn's model context", c do
    assert {:ok, %{turn_id: first}} =
             Agents.submit_prompt(
               %{thread_id: c.thread.id, prompt: "first", request_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert {:ok, _} =
             Agents.submit_prompt(
               %{thread_id: c.thread.id, prompt: "future", request_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert :ok = loop_tick(c)
    assert [%{request: %{"input" => messages}}] = Ledger.read!(ModelCall, turn_id: first)
    assert Enum.any?(messages, &(&1["content"] == "first"))
    refute Enum.any?(messages, &(&1["content"] == "future"))
  end

  test "Ziggy's control socket claims and returns a model result", c do
    turn = start_turn(c)
    assert {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")

    assert {:ok, %{"call" => %{"id" => id, "claim_id" => claim_id}}} =
             control_request(c.token, "agent_next", %{"version" => 2})

    assert id == call.id

    completion = %{
      "version" => 2,
      "call_id" => id,
      "claim_id" => claim_id,
      "response" => %{"choices" => [%{"message" => %{"content" => "Done"}}]}
    }

    assert control_request(c.token, "agent_result", completion) == {:ok, %{"acknowledged" => id}}
    assert [%{status: :completed}] = Ledger.read!(Turn, id: turn.id)
  end

  test "validated tool calls persist commands and an ordered private event", c do
    turn = start_turn(c)
    assert {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)

    response = %{
      "status" => "completed",
      "output" => [
        %{"type" => "reasoning", "encrypted_content" => "opaque"},
        %{
          "type" => "function_call",
          "call_id" => "call-1",
          "name" => "exec_command",
          "arguments" => ~s({"cmd":"pwd"})
        }
      ]
    }

    assert {:ok, _} = ModelCalls.complete(c.token, call.id, work.claim_id, response)

    assert [%{tool: :exec_command, status: :queued, arguments: %{"cmd" => "pwd"}}] =
             Ledger.read!(Command, turn_id: turn.id)

    assert [%{kind: :tool_queued}] = Ledger.read!(Event, turn_id: turn.id, kind: :tool_queued)
    assert [%{status: :running}] = Ledger.read!(Turn, id: turn.id)
  end

  test "Marshall claims web search without exposing it to the guest executor", c do
    turn = start_turn(c)
    {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")
    {:ok, %{call: model_work}} = ModelCalls.claim(c.token)

    response = %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "function_call",
          "call_id" => "search-1",
          "name" => "web_search",
          "arguments" => ~s({"query":"example topic"})
        }
      ]
    }

    assert {:ok, _} = ModelCalls.complete(c.token, call.id, model_work.claim_id, response)

    assert [%{tool: :web_search, status: :queued} = command] =
             Ledger.read!(Command, turn_id: turn.id)

    binding = %{
      "host_id" => c.vm.host_id,
      "vm_id" => c.vm.id,
      "placement_id" => c.vm.current_placement_id,
      "execution_epoch" => c.vm.execution_epoch
    }

    assert {:ok, executor} = ExecutorSession.register(binding, nil, ["context-v1"])
    assert {:ok, nil} = ExecutorSession.claim(binding, executor.id, executor.fence_epoch)
    assert {:ok, %{id: id, claim_id: claim_id}} = WebSearch.claim()
    assert id == command.id
    assert {:ok, nil} = WebSearch.claim()

    result = %{
      "answer_box" => nil,
      "results" => [%{"title" => "One", "url" => "https://example.org", "snippet" => "summary"}]
    }

    assert {:ok, :ok} = WebSearch.complete(id, claim_id, :completed, result, 2)
    assert {:ok, :stale} = WebSearch.complete(id, claim_id, :completed, result, 2)
    assert [%{credits: 2, cache_hit: false}] = Ledger.read!(SearchUsage, command_id: id)

    assert [%{kind: :tool_dispatched}] =
             Ledger.read!(AuditEvent, target_id: id, kind: :tool_dispatched)

    assert [%{kind: :tool_finished}] =
             Ledger.read!(AuditEvent, target_id: id, kind: :tool_finished)

    assert :ok = loop_tick(c)

    assert [%{request: %{"input" => input}}] =
             Ledger.read!(ModelCall, turn_id: turn.id, iteration: 2)

    assert Enum.any?(input, fn item ->
             item["type"] == "function_call_output" and
               Jason.decode!(item["output"])["results"] == result["results"]
           end)
  end

  test "identical searches use the shared cache until its 24-hour expiry", c do
    turn = start_turn(c)

    queue = fn call_id ->
      Ledger.create!(Command, :queue, %{
        root_id: c.thread.root_id,
        thread_id: c.thread.id,
        turn_id: turn.id,
        call_id: call_id,
        tool: :web_search,
        arguments: %{"query" => "  cached query  "}
      })
    end

    first = queue.("first")
    assert {:ok, %{id: first_id, claim_id: first_claim}} = WebSearch.claim()
    assert first_id == first.id
    result = %{"answer_box" => nil, "results" => []}
    assert {:ok, :ok} = WebSearch.complete(first.id, first_claim, :completed, result, 3)

    second = queue.("second")
    assert {:ok, nil} = WebSearch.claim()
    assert [%{status: :completed, result: ^result}] = Ledger.read!(Command, id: second.id)
    assert [%{credits: 0, cache_hit: true}] = Ledger.read!(SearchUsage, command_id: second.id)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE agent_search_cache SET fetched_at = now() - interval '25 hours' WHERE key = $1",
      [WebSearch.cache_key("cached query")]
    )

    third = queue.("third")
    assert {:ok, %{id: third_id, claim_id: third_claim}} = WebSearch.claim()
    assert third_id == third.id

    assert {:ok, :ok} =
             WebSearch.complete(
               third.id,
               third_claim,
               :failed,
               %{"reason" => "search_failed"},
               nil
             )
  end

  test "revoked actor cannot claim a queued web search", c do
    turn = start_turn(c)

    command =
      Ledger.create!(Command, :queue, %{
        root_id: c.thread.root_id,
        thread_id: c.thread.id,
        turn_id: turn.id,
        call_id: "revoked-search",
        tool: :web_search,
        arguments: %{"query" => "private"}
      })

    Ledger.update!(c.actor, :security_state, %{deleted_at: Ledger.now()})
    assert {:ok, nil} = WebSearch.claim()
    assert [%{status: :cancelled}] = Ledger.read!(Command, id: command.id)
    assert [%{credits: nil, outcome: :failed}] = Ledger.read!(SearchUsage, command_id: command.id)
  end

  @tag :tmp_dir
  test "encrypted placeholder reaches the worker but never calls the provider", c do
    turn = start_turn(c)
    key_file = Path.join(c.tmp_dir, "serper.key")
    File.write!(key_file, "overalls-serper-placeholder-v1-" <> String.duplicate("a", 64))
    previous = Application.get_env(:marshall, :serper_key_file)
    Application.put_env(:marshall, :serper_key_file, key_file)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:marshall, :serper_key_file),
        else: Application.put_env(:marshall, :serper_key_file, previous)
    end)

    command =
      Ledger.create!(Command, :queue, %{
        root_id: c.thread.root_id,
        thread_id: c.thread.id,
        turn_id: turn.id,
        call_id: "placeholder",
        tool: :web_search,
        arguments: %{"query" => "example"}
      })

    assert {:ok, work} = WebSearch.claim()
    assert :ok = WebSearch.run(work)

    assert [%{status: :failed, result: %{"reason" => "search_unavailable"}}] =
             Ledger.read!(Command, id: command.id)
  end

  test "Standard rejects a mixed tool response without dispatching any tool", c do
    turn = start_turn(c)
    assert {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")

    assert Enum.map(call.request["tools"], & &1["name"]) ==
             ~w(exec_command read_file web_search web_fetch)

    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)

    response = %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "function_call",
          "call_id" => "allowed",
          "name" => "read_file",
          "arguments" => ~s({"path":"/etc/hostname"})
        },
        %{
          "type" => "function_call",
          "call_id" => "denied",
          "name" => "spawn_child_agent",
          "arguments" => ~s({"title":"child","prompt":"work"})
        }
      ]
    }

    assert {:ok, _} = ModelCalls.complete(c.token, call.id, work.claim_id, response)

    assert [%{status: :failed, failure_reason: :capability_denied}] =
             Ledger.read!(Turn, id: turn.id)

    assert [] = Ledger.read!(Command, turn_id: turn.id)
    assert [] = Ledger.read!(Thread, parent_thread_id: c.thread.id)
    assert [] = Ledger.read!(Event, turn_id: turn.id, kind: :model_output)

    assert [%{kind: :model_finished, outcome: :failed}] =
             Ledger.read!(AuditEvent, target_id: call.id, kind: :model_finished)
  end

  test "a queued request from an older policy cannot advertise a removed tool", c do
    turn = start_turn(c)

    call =
      Ledger.create!(ModelCall, :queue, %{
        root_id: c.thread.root_id,
        thread_id: c.thread.id,
        turn_id: turn.id,
        iteration: 1,
        host_id: c.vm.host_id,
        placement_id: c.vm.current_placement_id,
        execution_epoch: c.vm.execution_epoch,
        request: %{
          "tools" => [%{"type" => "function", "name" => "spawn_child_agent"}]
        }
      })

    assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)

    assert [%{status: :cancelled, response: %{"reason" => "capability_denied"}}] =
             Ledger.read!(ModelCall, id: call.id)

    assert :ok = loop_tick(c)

    assert [%{status: :failed, failure_reason: :capability_denied}] =
             Ledger.read!(Turn, id: turn.id)

    assert [%{kind: :model_finished, outcome: :failed}] =
             Ledger.read!(AuditEvent, target_id: call.id, kind: :model_finished)
  end

  test "queued native maintenance is cancelled when verification is disabled", c do
    previous = Application.get_env(:marshall, :agent_context_policy)
    Application.put_env(:marshall, :agent_context_policy, %{native_compaction_capabilities: []})

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:marshall, :agent_context_policy),
        else: Application.put_env(:marshall, :agent_context_policy, previous)
    end)

    turn = start_turn(c)

    call =
      Ledger.create!(ModelCall, :queue, %{
        root_id: c.thread.root_id,
        thread_id: c.thread.id,
        turn_id: turn.id,
        iteration: 1,
        host_id: c.vm.host_id,
        placement_id: c.vm.current_placement_id,
        execution_epoch: c.vm.execution_epoch,
        purpose: :native,
        request: %{
          "input" => [%{"type" => "compaction_trigger"}],
          "tools" => [],
          "tool_choice" => "none",
          "store" => false,
          "stream" => true
        }
      })

    assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)

    assert [%{status: :cancelled, response: %{"reason" => "capability_denied"}}] =
             Ledger.read!(ModelCall, id: call.id)
  end

  test "Responses output is retained privately for stateless tool continuation", c do
    turn = start_turn(c)
    assert {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)

    response = %{
      "status" => "completed",
      "output" => [
        %{"type" => "reasoning", "encrypted_content" => "opaque"},
        %{
          "type" => "function_call",
          "call_id" => "call-1",
          "name" => "read_file",
          "arguments" => ~s({"path":"/etc/hostname"})
        }
      ]
    }

    assert {:ok, _} = ModelCalls.complete(c.token, call.id, work.claim_id, response)

    assert [%{body: %{"output" => output}}] =
             Ledger.read!(Event, turn_id: turn.id, kind: :model_output)

    assert output == response["output"]
    assert [%{tool: :read_file, status: :queued}] = Ledger.read!(Command, turn_id: turn.id)
    assert {:ok, visible} = Marshall.Agents.Conversation.events(c.thread.id, c.actor)
    refute Enum.any?(visible, &(&1.kind == :model_output))
  end

  test "server tick moves prompt through model and fenced guest tool back to model", c do
    assert {:ok, %{turn_id: turn_id}} =
             Agents.submit_prompt(
               %{thread_id: c.thread.id, prompt: "inspect", request_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert :ok = loop_tick(c)
    assert [%{iteration: 1, status: :queued} = call] = Ledger.read!(ModelCall, turn_id: turn_id)
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)

    response = %{
      "status" => "completed",
      "output" => [
        %{"type" => "reasoning", "encrypted_content" => "opaque"},
        %{
          "type" => "function_call",
          "call_id" => "call-1",
          "name" => "exec_command",
          "arguments" => ~s({"cmd":"pwd"})
        }
      ]
    }

    assert {:ok, _} = ModelCalls.complete(c.token, call.id, work.claim_id, response)

    binding = %{
      "host_id" => c.vm.host_id,
      "vm_id" => c.vm.id,
      "placement_id" => c.vm.current_placement_id,
      "execution_epoch" => c.vm.execution_epoch
    }

    assert {:ok, executor} = ExecutorSession.register(binding, nil, ["context-v1"])
    assert {:ok, command} = ExecutorSession.claim(binding, executor.id, executor.fence_epoch)

    assert {:ok, _} =
             ExecutorSession.transition(
               binding,
               executor.id,
               executor.fence_epoch,
               command.id,
               :started
             )

    assert {:ok, _} =
             ExecutorSession.transition(
               binding,
               executor.id,
               executor.fence_epoch,
               command.id,
               :completed,
               %{"stdout" => "/workspace"}
             )

    assert :ok = loop_tick(c)

    assert [%{body: %{"call_id" => "call-1"}}] =
             Ledger.read!(Event, turn_id: turn_id, kind: :tool_result)

    assert [%{request: %{"input" => input}}] =
             Enum.filter(Ledger.read!(ModelCall, turn_id: turn_id), &(&1.iteration == 2))

    assert Enum.any?(input, &(&1["encrypted_content"] == "opaque"))
    assert Enum.any?(input, &(&1["type"] == "function_call_output"))
  end

  test "an expired claimed attempt becomes uncertain without a provider retry", c do
    turn = start_turn(c)
    assert {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)
    [claimed] = Ledger.read!(ModelCall, id: call.id)
    Ledger.update!(claimed, :transition, %{claimed_at: DateTime.add(Ledger.now(), -601, :second)})

    assert :ok = ModelCalls.reap()
    assert [%{status: :uncertain}] = Ledger.read!(ModelCall, id: call.id)

    assert [%{status: :failed, failure_reason: :provider_failed}] =
             Ledger.read!(Turn, id: turn.id)

    assert {:error, _} =
             ModelCalls.complete(c.token, call.id, work.claim_id, %{
               "choices" => [%{"message" => %{"content" => "late"}}]
             })

    assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)
  end

  test "claimed model work never requeues across the expiry boundary", c do
    Hegel.check(
      fn ->
        extra_polls = draw("extra_polls", integer(1..4))

        for age <- [590, 601] do
          assert {:ok, thread} = Conversation.spawn_child(c.thread.id, "claim history", c.actor)
          turn = start_turn(%{c | thread: thread})
          assert {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")
          assert {:ok, %{call: work}} = ModelCalls.claim(c.token)
          [claimed] = Ledger.read!(ModelCall, id: call.id)

          %{rows: [[database_now]]} =
            Ecto.Adapters.SQL.query!(Marshall.Repo, "SELECT now()", [], log: false)

          Ledger.update!(claimed, :transition, %{claimed_at: DateTime.add(database_now, -age)})

          assert :ok = ModelCalls.reap()

          for _ <- 1..extra_polls do
            assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)
          end

          assert [%{kind: :model_dispatched}] =
                   Ledger.read!(AuditEvent, target_id: call.id, kind: :model_dispatched)

          if age > 600 do
            assert [%{status: :uncertain, claim_id: claim_id}] =
                     Ledger.read!(ModelCall, id: call.id)

            assert claim_id == work.claim_id

            assert [%{status: :failed, failure_reason: :provider_failed}] =
                     Ledger.read!(Turn, id: turn.id)

            assert {:error, _} =
                     ModelCalls.complete(c.token, call.id, work.claim_id, %{
                       "choices" => [%{"message" => %{"content" => "late"}}]
                     })

            assert [%{kind: :model_finished, outcome: :uncertain}] =
                     Ledger.read!(AuditEvent, target_id: call.id, kind: :model_finished)
          else
            assert [%{status: :claimed, claim_id: claim_id}] =
                     Ledger.read!(ModelCall, id: call.id)

            assert claim_id == work.claim_id

            assert {:ok, %{acknowledged: id}} =
                     ModelCalls.complete(c.token, call.id, work.claim_id, %{
                       "choices" => [%{"message" => %{"content" => "delivered"}}]
                     })

            assert id == call.id
            assert [%{status: :completed}] = Ledger.read!(ModelCall, id: call.id)

            assert [%{kind: :model_finished, outcome: :completed}] =
                     Ledger.read!(AuditEvent, target_id: call.id, kind: :model_finished)
          end
        end
      end,
      test_cases: 100
    )
  end

  test "a queued model call is cancelled when the VM execution changes", c do
    turn = start_turn(c)
    assert {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE compute_virtual_machines SET execution_epoch = execution_epoch + 1 WHERE id = $1",
      [Ecto.UUID.dump!(c.vm.id)]
    )

    assert :ok = loop_tick(c)
    assert [%{status: :cancelled}] = Ledger.read!(ModelCall, id: call.id)

    assert [%{status: :failed, failure_reason: :machine_unavailable}] =
             Ledger.read!(Turn, id: turn.id)

    assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)

    assert [%{kind: :model_finished, outcome: :failed}] =
             Ledger.read!(AuditEvent, target_id: call.id, kind: :model_finished)
  end

  test "a claimed model result cannot dispatch tools after the VM execution changes", c do
    turn = start_turn(c)
    assert {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE compute_virtual_machines SET execution_epoch = execution_epoch + 1 WHERE id = $1",
      [Ecto.UUID.dump!(c.vm.id)]
    )

    response = %{
      "choices" => [
        %{
          "message" => %{
            "tool_calls" => [
              %{
                "id" => "late-tool",
                "type" => "function",
                "function" => %{"name" => "exec_command", "arguments" => ~s({"cmd":"pwd"})}
              }
            ]
          }
        }
      ]
    }

    assert {:ok, _} = ModelCalls.complete(c.token, call.id, work.claim_id, response)
    assert [%{status: :uncertain}] = Ledger.read!(ModelCall, id: call.id)
    assert [] = Ledger.read!(Command, turn_id: turn.id)

    assert [%{status: :failed, failure_reason: :machine_unavailable}] =
             Ledger.read!(Turn, id: turn.id)
  end

  test "revoked prompt actor cannot cause a later model tool dispatch", c do
    turn = start_turn(c)
    assert {:ok, call} = ModelCalls.queue(turn.id, "gpt-6-sol")
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)
    Ledger.update!(c.actor, :security_state, %{deleted_at: Ledger.now()})

    response = %{
      "choices" => [
        %{
          "message" => %{
            "tool_calls" => [
              %{
                "id" => "call-1",
                "type" => "function",
                "function" => %{"name" => "exec_command", "arguments" => ~s({"cmd":"pwd"})}
              }
            ]
          }
        }
      ]
    }

    assert {:ok, _} = ModelCalls.complete(c.token, call.id, work.claim_id, response)
    assert [] = Ledger.read!(Command, turn_id: turn.id)
    assert [%{status: :failed, failure_reason: :access_revoked}] = Ledger.read!(Turn, id: turn.id)
  end

  @tag profile: :oss
  test "two spawned child agents run independently and join the parent turn", c do
    parent = start_turn(c)
    assert {:ok, call} = ModelCalls.queue(parent.id, "gpt-6-sol")
    assert {:ok, %{call: claimed}} = ModelCalls.claim(c.token)

    child_calls =
      for number <- 1..2 do
        %{
          "id" => "child-#{number}",
          "type" => "function",
          "function" => %{
            "name" => "spawn_child_agent",
            "arguments" => Jason.encode!(%{title: "Child #{number}", prompt: "work #{number}"})
          }
        }
      end

    assert {:ok, _} =
             ModelCalls.complete(c.token, call.id, claimed.claim_id, %{
               "choices" => [%{"message" => %{"tool_calls" => child_calls}}]
             })

    assert length(Ledger.read!(Thread, parent_thread_id: c.thread.id)) == 2

    assert :ok = loop_tick(c)
    child_events = Ledger.read!(Event, turn_id: parent.id, kind: :child_spawned)
    assert length(child_events) == 2
    child_turn_ids = Enum.map(child_events, & &1.body["child_turn_id"])

    assert Enum.all?(child_turn_ids, fn id ->
             match?([%{status: :running}], Ledger.read!(Turn, id: id))
           end)

    for child_turn_id <- child_turn_ids do
      assert [%{status: :queued} = child_call] =
               Ledger.read!(ModelCall, turn_id: child_turn_id)

      assert {:ok, %{call: work}} = ModelCalls.claim(c.token)
      assert work.id == child_call.id

      assert {:ok, _} =
               ModelCalls.complete(c.token, child_call.id, work.claim_id, %{
                 "choices" => [%{"message" => %{"content" => "child done"}}]
               })
    end

    assert :ok = loop_tick(c)
    assert length(Ledger.read!(Event, turn_id: parent.id, kind: :tool_result)) == 2

    assert Enum.any?(
             Ledger.read!(ModelCall, turn_id: parent.id),
             &(&1.iteration == 2 and &1.status == :queued)
           )
  end

  defp start_turn(c) do
    assert {:ok, %{turn_id: id}} =
             Agents.submit_prompt(
               %{thread_id: c.thread.id, prompt: "work", request_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert {:ok, %{id: ^id} = turn} = TurnCoordinator.claim_next()
    applied_context_fixture(turn, c)
    turn
  end

  @spec loop_tick(map()) :: :ok
  defp loop_tick(c) do
    for thread <- Ledger.read!(Thread, root_id: c.thread.root_id),
        turn <- Ledger.read!(Turn, thread_id: thread.id),
        turn.status in [:queued, :running] do
      applied_context_fixture(turn, c)
    end

    Loop.tick()
  end

  # These provider-state tests begin with synthetic applied context. Guest reads
  # and source verification are exercised by Context and planning-loop tests.
  @spec applied_context_fixture(Turn.t(), map()) :: ContextSnapshot.t()
  defp applied_context_fixture(turn, c) do
    Context.snapshot(turn.id) ||
      Ledger.create!(ContextSnapshot, :capture, %{
        thread_id: turn.thread_id,
        turn_id: turn.id,
        generation: 1,
        configuration_owner_id: c.actor.id,
        guest_account_id: c.account.id,
        working_directory: "/workspace",
        creator_home: "/home/" <> c.account.username,
        collaboration_mode: turn.collaboration_mode,
        reasoning: turn.mode,
        inventory_digest: String.duplicate("a", 64),
        host_id: c.vm.host_id,
        placement_id: c.vm.current_placement_id,
        execution_epoch: c.vm.execution_epoch,
        executor_id: current_executor(c).id,
        fence_epoch: current_executor(c).fence_epoch
      })
  end

  @spec current_executor(map()) :: Executor.t()
  defp current_executor(c) do
    Ledger.read!(Executor, root_id: c.thread.root_id)
    |> Enum.find(&is_nil(&1.invalidated_at))
  end

  @spec control_request(String.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  defp control_request(token, route, body) do
    {:ok, principal} = Marshall.Control.Services.Ziggy.authenticate(token)
    Marshall.Control.Services.Ziggy.handle_request("ziggy." <> route, body, principal)
  end
end
