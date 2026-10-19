defmodule Marshall.Agents.ExecutorSessionTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures

  alias Marshall.Agents.{
    AuditEvent,
    Command,
    ExecutorRPC,
    ExecutorSession,
    Root,
    Thread,
    Turn
  }

  alias Marshall.Compute
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes}
  alias Marshall.Inference.Credentials

  # @cc [owner:ghuntley,label:verification;security] executor-rpc-current-host-fixture
  # Authenticated bootstrap claims MUST exercise a real current provisioner
  # session and fresh report, not bypass host-liveness authority with seeded fields.
  setup do
    fixture = host_fixture()
    {:ok, credential} = Marshall.Compute.Credentials.rotate(fixture.host.id, 3600)

    {:ok, session} =
      Marshall.Compute.ProvisionerControl.open_execution(credential.token, %{
        session_id: Ash.UUID.generate(),
        machine_id: fixture.host.machine_id
      })

    {:ok, _} =
      Marshall.Compute.ProvisionerControl.exchange_execution(credential.token, %{
        session_id: session["session_id"],
        epoch: session["epoch"],
        report: fixture.report,
        acknowledgements: [],
        outcomes: []
      })

    actor = user()
    {:ok, vm} = Compute.provision(request(), actor: actor)
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

    binding = %{
      "host_id" => vm.host_id,
      "vm_id" => vm.id,
      "placement_id" => vm.current_placement_id,
      "execution_epoch" => vm.execution_epoch
    }

    %{actor: actor, binding: binding, root: root, thread: thread, vm: vm}
  end

  test "replacement fences stale results and preserves an ambiguous tool as uncertain", c do
    {:ok, first} = ExecutorSession.register(c.binding)

    turn =
      Ledger.create!(Turn, :enqueue, %{
        thread_id: c.thread.id,
        actor_id: c.actor.id,
        request_key: Ash.UUID.generate(),
        ordinal: 1,
        prompt: "run command"
      })

    Ledger.update!(turn, :transition, %{status: :running, started_at: Ledger.now()})
    Ledger.update!(c.thread, :advance, %{active_turn_id: turn.id})

    command =
      Ledger.create!(Command, :queue, %{
        root_id: c.root.id,
        thread_id: c.thread.id,
        turn_id: turn.id,
        call_id: "call-1",
        tool: :exec_command,
        arguments: %{"cmd" => "touch marker"}
      })

    assert {:ok, %{id: id, status: :claimed}} =
             ExecutorSession.claim(c.binding, first.id, first.fence_epoch)

    assert id == command.id

    assert {:ok, %{status: :started}} =
             ExecutorSession.transition(
               c.binding,
               first.id,
               first.fence_epoch,
               command.id,
               :started
             )

    assert {:ok, second} = ExecutorSession.register(c.binding)
    assert second.fence_epoch == first.fence_epoch + 1
    assert [%{status: :uncertain}] = Ledger.read!(Command, id: command.id)

    assert {:error, _} =
             ExecutorSession.transition(
               c.binding,
               first.id,
               first.fence_epoch,
               command.id,
               :completed
             )

    assert {:ok, nil} = ExecutorSession.claim(c.binding, second.id, second.fence_epoch)
    assert [%{kind: :tool_dispatched}] = Ledger.read!(AuditEvent, target_id: command.id)
  end

  test "binary digest registration is persisted and produces a content-free update audit", c do
    first_digest = String.duplicate("a", 64)
    second_digest = String.duplicate("b", 64)
    {:ok, first} = ExecutorSession.register(c.binding, first_digest)
    assert first.binary_sha256 == first_digest

    {:ok, issued} = Credentials.rotate(c.vm.host_id, 3600)
    token = issued.id <> "." <> issued.secret

    assert {:ok, %{executor_id: second_id}} =
             ExecutorRPC.request(token, "register", %{
               "binding" => c.binding,
               "digest" => second_digest
             })

    assert [%{binary_sha256: ^second_digest}] =
             Ledger.read!(Marshall.Agents.Executor, id: second_id)

    assert [%{kind: :executor_updated, outcome: :accepted, target_id: ^second_id}] =
             Ledger.read!(AuditEvent, target_id: second_id)

    assert {:error, :invalid_request} =
             ExecutorRPC.request(token, "register", %{
               "binding" => c.binding,
               "digest" => "not-a-digest"
             })
  end

  test "forged placement and host bindings cannot register a lease", c do
    for field <- ["host_id", "placement_id", "execution_epoch"] do
      value = if field == "execution_epoch", do: 999, else: Ash.UUID.generate()
      assert {:error, _} = ExecutorSession.register(Map.put(c.binding, field, value))
    end
  end

  test "host credential authenticates guest RPC while binding and lease fence remain authoritative",
       c do
    {:ok, issued} = Credentials.rotate(c.vm.host_id, 3600)
    token = issued.id <> "." <> issued.secret

    assert {:ok, %{executor_id: id, fence_epoch: fence}} =
             ExecutorRPC.request(token, "register", %{"binding" => c.binding})

    assert {:ok, %{expires_at_ms: expiry}} =
             ExecutorRPC.request(token, "heartbeat", %{
               "binding" => c.binding,
               "executor_id" => id,
               "fence_epoch" => fence
             })

    assert is_integer(expiry)

    assert {:ok, %{command: nil}} =
             ExecutorRPC.request(token, "claim", %{
               "binding" => c.binding,
               "executor_id" => id,
               "fence_epoch" => fence
             })

    assert {:error, _} =
             ExecutorRPC.request(token, "register", %{
               "binding" => Map.put(c.binding, "host_id", Ash.UUID.generate())
             })

    assert {:error, _} =
             ExecutorRPC.request(String.duplicate("x", 80), "register", %{"binding" => c.binding})

    assert {:error, :invalid_request} =
             ExecutorRPC.request(token, "transition", %{
               "binding" => c.binding,
               "executor_id" => id,
               "fence_epoch" => fence,
               "command_id" => Ash.UUID.generate(),
               "status" => "other"
             })
  end

  test "Ziggy's control socket registers an executor without leaking its token", c do
    {:ok, issued} = Credentials.rotate(c.vm.host_id, 3600)
    token = issued.id <> "." <> issued.secret
    {:ok, principal} = Marshall.Control.Services.Ziggy.authenticate(token)

    assert {:ok, %{"executor_id" => _, "fence_epoch" => 1, "expires_at_ms" => _} = response} =
             Marshall.Control.Services.Ziggy.handle_request(
               "ziggy.agent_register",
               %{"version" => 2, "binding" => c.binding},
               principal
             )

    refute String.contains?(JSON.encode!(response), token)
  end

  test "registration stores a closed capability set and omission advertises no new operations",
       c do
    assert {:ok, %{capabilities: []}} = ExecutorSession.register(c.binding)
    {:ok, issued} = Credentials.rotate(c.vm.host_id, 3600)
    token = issued.id <> "." <> issued.secret

    assert {:ok, %{executor_id: id}} =
             ExecutorRPC.request(token, "register", %{
               "binding" => c.binding,
               "capabilities" => ["skills-v1", "context-v1"]
             })

    assert [%{capabilities: ["context-v1", "skills-v1"]}] =
             Ledger.read!(Marshall.Agents.Executor, id: id)

    for capabilities <- [nil, "context-v1", ["context-v2"], ["context-v1", "context-v1"], [1]] do
      assert {:error, :invalid_request} =
               ExecutorRPC.request(token, "register", %{
                 "binding" => c.binding,
                 "capabilities" => capabilities
               })
    end
  end

  test "an old guest receives no internal command and its refusal is durable", c do
    {:ok, executor} = ExecutorSession.register(c.binding)
    command = internal_command(c, :context_inventory, %{"version" => 1})
    assert {:ok, nil} = ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)

    assert [
             %{
               status: :failed,
               executor_id: nil,
               result: %{"reason" => "executor_upgrade_required"}
             }
           ] =
             Ledger.read!(Command, id: command.id)

    assert [%{kind: :tool_finished, outcome: :failed}] =
             Ledger.read!(AuditEvent, target_id: command.id)

    assert {:ok, nil} = ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)
    assert length(Ledger.read!(AuditEvent, target_id: command.id)) == 1
  end

  test "capable guest receives version-one context work through the existing fenced lease", c do
    {:ok, executor} = ExecutorSession.register(c.binding, nil, ["context-v1"])
    command = internal_command(c, :context_inventory, %{"version" => 1})
    id = command.id

    assert {:ok, %{id: ^id, status: :claimed}} =
             ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)

    assert {:ok, %{status: :started}} =
             ExecutorSession.transition(
               c.binding,
               executor.id,
               executor.fence_epoch,
               id,
               :started
             )

    assert {:ok, %{status: :completed}} =
             ExecutorSession.transition(
               c.binding,
               executor.id,
               executor.fence_epoch,
               id,
               :completed,
               %{"version" => 1, "entries" => []}
             )
  end

  test "internal command version is checked before claim and again before start", c do
    {:ok, executor} = ExecutorSession.register(c.binding, nil, ["context-v1"])
    command = internal_command(c, :context_read, %{"version" => 2})
    assert {:ok, nil} = ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)

    assert [%{status: :failed, result: %{"reason" => "invalid_internal_command"}}] =
             Ledger.read!(Command, id: command.id)

    [turn] = Ledger.read!(Turn, id: command.turn_id)
    Ledger.update!(turn, :transition, %{status: :failed, finished_at: Ledger.now()})

    command = internal_command(c, :context_read, %{"version" => 1}, 2)

    assert {:ok, %{status: :claimed}} =
             ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE agent_commands SET arguments = $2 WHERE id = $1",
      [Ecto.UUID.dump!(command.id), %{"version" => 2}],
      log: false
    )

    assert {:error, :invalid_internal_command} =
             ExecutorSession.transition(
               c.binding,
               executor.id,
               executor.fence_epoch,
               command.id,
               :started
             )

    assert [%{status: :claimed}] = Ledger.read!(Command, id: command.id)
  end

  test "start rechecks the persisted capability before the guest performs internal work", c do
    {:ok, executor} = ExecutorSession.register(c.binding, nil, ["context-v1"])
    command = internal_command(c, :context_inventory, %{"version" => 1})

    assert {:ok, %{status: :claimed}} =
             ExecutorSession.claim(c.binding, executor.id, executor.fence_epoch)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE agent_executors SET capabilities = '{}'::text[] WHERE id = $1",
      [Ecto.UUID.dump!(executor.id)],
      log: false
    )

    assert {:error, :executor_upgrade_required} =
             ExecutorSession.transition(
               c.binding,
               executor.id,
               executor.fence_epoch,
               command.id,
               :started
             )

    assert [%{status: :claimed}] = Ledger.read!(Command, id: command.id)
  end

  @spec internal_command(map(), atom(), map(), pos_integer()) :: Command.t()
  defp internal_command(c, tool, arguments, ordinal \\ 1) do
    turn =
      Ledger.create!(Turn, :enqueue, %{
        thread_id: c.thread.id,
        actor_id: c.actor.id,
        request_key: Ash.UUID.generate(),
        ordinal: ordinal,
        prompt: "prepare context"
      })

    Ledger.update!(turn, :transition, %{status: :running, started_at: Ledger.now()})
    [thread] = Ledger.read!(Thread, id: c.thread.id)
    Ledger.update!(thread, :advance, %{active_turn_id: turn.id})

    Ledger.create!(Command, :queue, %{
      root_id: c.root.id,
      thread_id: c.thread.id,
      turn_id: turn.id,
      call_id: "internal-#{ordinal}",
      tool: tool,
      arguments: arguments
    })
  end
end
