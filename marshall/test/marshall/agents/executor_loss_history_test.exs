defmodule Marshall.Agents.ExecutorLossHistoryTest do
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Accounts.User
  alias Marshall.Agents.{AuditEvent, CLIAccess, Command, Event, Executor, ExecutorSession}
  alias Marshall.Agents.{Loop, ModelCall, ModelCalls, Root, Thread, Turn}
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes, VirtualMachine}
  alias Marshall.ComputeFixtures, as: Fixtures

  @moduletag capture_log: true
  @type scenario :: {:claimed | :started, :replace | :expire, :allowed | :revoked}
  @type fixture :: %{
          owner: User.t(),
          actor: User.t(),
          vm: VirtualMachine.t(),
          thread: Thread.t(),
          binding: %{String.t() => String.t() | pos_integer()},
          secret: String.t(),
          token: String.t()
        }
  @type inventory :: %{String.t() => [String.t()]}

  # @cc [owner:ghuntley,label:verification;recovery] composed-executor-loss-histories
  # Every generated history MUST compose actual CLI authorization, prompt/model
  # coordination and executor transitions. Expected cancellation/uncertainty
  # MUST follow the generated start boundary, independently of SUT predicates.
  # SQL sandbox observations and synthetic expiry establish durable dispatch
  # policy only; they MUST NOT be described as real guest side effects or TLS.
  property "executor loss preserves one dispatch and requires authorized explicit retry",
    test_cases: 3 do
    scenarios =
      for state <- [:claimed, :started],
          loss <- [:replace, :expire],
          access <- [:allowed, :revoked],
          do: {state, loss, access}

    check all(order <- shuffle(scenarios), repeats <- integer(1..3), test_cases: 3) do
      Enum.each(order, &history(&1, repeats))
    end
  end

  @spec history(scenario(), pos_integer()) :: :ok
  defp history({state, loss, access}, repeats) do
    c = fixture()
    key = Ash.UUID.generate()
    turn = submit!(c, key)
    {:ok, %{id: ^turn} = started} = Marshall.Agents.TurnCoordinator.claim_next()
    Marshall.AgentContextFixtures.context_fixture(started, c.vm, c.owner)
    assert :ok = Loop.tick()
    queue_tool!(c, turn)
    assert {:ok, first} = ExecutorSession.register(c.binding, nil, ["context-v1"])
    assert {:ok, command} = ExecutorSession.claim(c.binding, first.id, first.fence_epoch)
    assert command.turn_id == turn

    if state == :started do
      assert {:ok, %{status: :started}} =
               ExecutorSession.transition(
                 c.binding,
                 first.id,
                 first.fence_epoch,
                 command.id,
                 :started
               )
    end

    if loss == :expire do
      # Synthetic database-clock boundary, without waiting thirty real seconds.
      Ledger.update!(first, :heartbeat, %{expires_at: DateTime.add(Ledger.now(), -1, :second)})
      before = inventory()

      assert {:error, :stale_fence} =
               ExecutorSession.heartbeat(c.binding, first.id, first.fence_epoch)

      assert {:error, :stale_fence} =
               ExecutorSession.claim(c.binding, first.id, first.fence_epoch)

      refuse_late!(c, first, command)
      assert inventory() == before
      assert [%{status: ^state}] = Ledger.read!(Command, id: command.id)
    end

    assert {:ok, replacement} = ExecutorSession.register(c.binding, nil, ["context-v1"])
    assert replacement.id != first.id
    assert replacement.fence_epoch == first.fence_epoch + 1
    assert [%{invalidated_at: invalidated}] = Ledger.read!(Executor, id: first.id)
    assert is_struct(invalidated, DateTime)
    expected = if state == :started, do: :uncertain, else: :cancelled
    assert [%{status: ^expected}] = Ledger.read!(Command, id: command.id)

    for _ <- 1..repeats do
      before = inventory()
      refuse_late!(c, first, command)

      assert {:ok, nil} =
               ExecutorSession.claim(c.binding, replacement.id, replacement.fence_epoch)

      assert inventory() == before
    end

    assert :ok = Loop.tick()

    case state do
      :started ->
        assert result(c, turn) == %{
                 "id" => turn,
                 "status" => "failed",
                 "reason" => "tool_uncertain"
               }

        assert [_] = Ledger.read!(ModelCall, turn_id: turn)
        assert [] = Ledger.read!(Event, turn_id: turn, kind: :tool_result)

      :claimed ->
        # A never-started cancellation enters the ordinary tool-result path;
        # the isolated provider chooses to finish, without issuing another tool.
        assert [%{body: %{"result" => %{"status" => "cancelled"}}}] =
                 Ledger.read!(Event, turn_id: turn, kind: :tool_result)

        complete_model!(c, turn)
        assert result(c, turn) == %{"id" => turn, "status" => "completed", "text" => "done"}
        assert length(Ledger.read!(ModelCall, turn_id: turn)) == 2
    end

    assert [%{kind: :tool_dispatched}] = Ledger.read!(AuditEvent, target_id: command.id)
    retained = inventory()

    for _ <- 1..repeats do
      assert :ok = Loop.tick()
      assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)

      assert {:ok, nil} =
               ExecutorSession.claim(c.binding, replacement.id, replacement.fence_epoch)

      assert submit!(c, key) == turn
      assert inventory() == retained
    end

    if access == :revoked do
      share!(c, :revoked)
      before = inventory()
      assert prompt(c, Ash.UUID.generate()).status == 403
      assert prompt(c, key).status == 403
      assert api(c, :get, "/api/agents/v1/turn/#{turn}?vm_id=#{c.vm.id}").status == 403
      assert {:error, :unauthorized} = CLIAccess.authorize(c.vm.id, c.secret)
      assert inventory() == before
      # Re-grant through the actual access action before the explicit retry.
      share!(c, :operator)
    end

    prior_work =
      Map.take(inventory(), [
        "agent_commands",
        "agent_model_calls",
        "agent_events",
        "agent_turns",
        "agent_audit_events"
      ])

    retry = submit!(c, Ash.UUID.generate())
    assert retry != turn
    assert :ok = Loop.tick()
    queue_tool!(c, retry)

    assert {:ok, retry_command} =
             ExecutorSession.claim(c.binding, replacement.id, replacement.fence_epoch)

    assert retry_command.turn_id == retry
    assert retry_command.id != command.id

    assert {:ok, _} =
             ExecutorSession.transition(
               c.binding,
               replacement.id,
               replacement.fence_epoch,
               retry_command.id,
               :started
             )

    assert {:ok, _} =
             ExecutorSession.transition(
               c.binding,
               replacement.id,
               replacement.fence_epoch,
               retry_command.id,
               :completed,
               %{"stdout" => "synthetic result"}
             )

    assert :ok = Loop.tick()
    complete_model!(c, retry)
    assert result(c, retry) == %{"id" => retry, "status" => "completed", "text" => "done"}
    assert [%{status: ^expected}] = Ledger.read!(Command, id: command.id)
    assert length(Ledger.read!(Turn, thread_id: c.thread.id)) == 2
    assert [%{kind: :tool_dispatched}] = Ledger.read!(AuditEvent, target_id: command.id)
    assert length(tool_commands(thread_id: c.thread.id)) == 2
    after_retry = inventory()
    for {table, hashes} <- prior_work, do: assert(hashes -- Map.fetch!(after_retry, table) == [])

    for _ <- 1..repeats do
      assert :ok = Loop.tick()
      assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)

      assert {:ok, nil} =
               ExecutorSession.claim(c.binding, replacement.id, replacement.fence_epoch)

      assert inventory() == after_retry
    end

    :ok
  end

  @spec refuse_late!(fixture(), Executor.t(), Command.t()) :: :ok
  defp refuse_late!(c, executor, command) do
    for status <- [:started, :completed, :failed, :uncertain] do
      assert {:error, :stale_fence} =
               ExecutorSession.transition(
                 c.binding,
                 executor.id,
                 executor.fence_epoch,
                 command.id,
                 status,
                 %{"stdout" => "late"}
               )
    end

    :ok
  end

  @spec queue_tool!(fixture(), String.t()) :: :ok
  defp queue_tool!(c, turn) do
    settle_pending_context!(c, turn)
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)
    assert [%{turn_id: ^turn}] = Ledger.read!(ModelCall, id: work.id)

    assert {:ok, _} =
             ModelCalls.complete(c.token, work.id, work.claim_id, %{
               "status" => "completed",
               "output" => [
                 %{
                   "type" => "function_call",
                   "call_id" => "effect",
                   "name" => "exec_command",
                   "arguments" => ~s({"cmd":"fixture-effect"})
                 }
               ]
             })

    :ok
  end

  @spec complete_model!(fixture(), String.t()) :: :ok
  defp complete_model!(c, turn) do
    settle_pending_context!(c, turn)
    assert {:ok, %{call: work}} = ModelCalls.claim(c.token)
    assert [%{turn_id: ^turn, iteration: 2}] = Ledger.read!(ModelCall, id: work.id)
    assert Enum.any?(work.request["input"], &(&1["type"] == "function_call_output"))

    assert {:ok, _} =
             ModelCalls.complete(c.token, work.id, work.claim_id, %{
               "choices" => [%{"message" => %{"content" => "done"}}]
             })

    :ok
  end

  @spec fixture() :: fixture()
  defp fixture do
    Fixtures.host_fixture()
    owner = Fixtures.user()
    actor = Fixtures.user()
    {:ok, vm} = Marshall.Compute.provision(Fixtures.request(), actor: owner)
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
    {:ok, issued} = Marshall.Inference.Credentials.rotate(vm.host_id, 3600)
    secret = "overalls_agent_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    c = %{
      owner: owner,
      actor: actor,
      vm: vm,
      thread: thread,
      binding: %{
        "host_id" => vm.host_id,
        "vm_id" => vm.id,
        "placement_id" => vm.current_placement_id,
        "execution_epoch" => vm.execution_epoch
      },
      secret: secret,
      token: issued.id <> "." <> issued.secret
    }

    share!(c, :operator)
    code = Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
    assert {:ok, _} = CLIAccess.approve(vm.id, code, actor)
    c
  end

  @spec share!(fixture(), :operator | :revoked) :: :ok
  defp share!(c, role) do
    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: c.vm.id,
                 email: to_string(c.actor.email),
                 role: role,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    :ok
  end

  @spec submit!(fixture(), String.t()) :: String.t()
  defp submit!(c, key) do
    response = prompt(c, key)
    assert response.status == 200
    %{"turn_id" => id} = Jason.decode!(response.resp_body)
    id
  end

  @spec prompt(fixture(), String.t()) :: Plug.Conn.t()
  defp prompt(c, key),
    do:
      api(c, :post, "/api/agents/v1/prompt", %{
        vm_id: c.vm.id,
        thread_id: c.thread.id,
        request_key: key,
        prompt: "perform one fixture effect"
      })

  @spec result(fixture(), String.t()) :: map()
  defp result(c, turn) do
    response = api(c, :get, "/api/agents/v1/turn/#{turn}?vm_id=#{c.vm.id}")
    assert response.status == 200
    Jason.decode!(response.resp_body)
  end

  @spec api(fixture(), :get | :post, String.t(), map() | nil) :: Plug.Conn.t()
  defp api(c, method, path, body \\ nil) do
    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> c.secret)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(
      @endpoint,
      method,
      "https://www.example.com" <> path,
      if(body, do: Jason.encode!(body), else: "")
    )
  end

  # @cc [owner:ghuntley,label:verification] executor-history-complete-inventory
  # Refused calls and terminal polling MUST preserve every public-table row,
  # including unrelated prior fixtures. Hash all fields with multiplicity;
  # diagnostics MUST contain only table names and hashes, never private payloads.
  @spec inventory() :: inventory()
  defp inventory do
    %{rows: tables} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename",
        [],
        log: false
      )

    Map.new(tables, fn [name] ->
      quoted = "\"" <> String.replace(name, "\"", "\"\"") <> "\""

      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "SELECT md5(row_to_json(t)::text) FROM " <> quoted <> " t ORDER BY 1",
          [],
          log: false
        )

      {name, Enum.map(rows, fn [hash] -> hash end)}
    end)
  end

  # Context preparation leaves a completed context_inventory command; these
  # histories count only the tool commands the model requested.
  @spec tool_commands(keyword()) :: [Command.t()]
  defp tool_commands(filter),
    do: Command |> Ledger.read!(filter) |> Enum.reject(&(&1.tool == :context_inventory))

  # A turn re-prepares context after its contributing executor changed; settle
  # it through the real coordinator before expecting queued model work.
  @spec settle_pending_context!(map(), String.t()) :: :ok
  defp settle_pending_context!(c, turn) do
    case Marshall.Agents.Context.prepare(turn) do
      {:pending, _} ->
        [current] = Ledger.read!(Marshall.Agents.Turn, id: turn)
        Marshall.AgentContextFixtures.context_fixture(current, c.vm, c.owner)
        Loop.tick()

      _ ->
        :ok
    end
  end
end
