defmodule Marshall.Agents.ContextAuditTest do
  use Marshall.DataCase, async: false

  alias Marshall.Agents.{
    AuditEvent,
    Context,
    ContextCheckpoint,
    Root,
    Thread,
    Turn,
    TurnCoordinator
  }

  alias Marshall.Compute.Ledger
  import ExUnit.CaptureLog

  test "context publication is audited atomically and diagnostics exclude content" do
    %{owner: owner, vm: vm} = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    [root] = Ledger.read!(Root, vm_id: vm.id)
    [thread] = Ledger.read!(Thread, root_id: root.id)

    assert {:ok, %{turn_id: turn_id}} =
             Marshall.Agents.submit_prompt(
               %{
                 thread_id: thread.id,
                 prompt: "private-context-fixture",
                 request_key: Ash.UUID.generate()
               },
               actor: owner
             )

    assert {:ok, %Turn{id: ^turn_id} = turn} = TurnCoordinator.claim_next()
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    capture =
      capture_log([metadata: [:event, :kind]], fn ->
        snapshot = Marshall.AgentContextFixtures.context_fixture(turn, vm, owner)
        assert {:ok, replay} = Context.prepare(turn_id)
        assert replay.id == snapshot.id
      end)

    assert length(Regex.scan(~r/event=agent\.context_published/, capture)) == 1
    assert capture =~ "kind=context_captured"
    refute capture =~ "private-context-fixture"
    assert [receipt] = Ledger.read!(AuditEvent, turn_id: turn_id, kind: :context_captured)
    assert receipt.actor_id == owner.id
    assert receipt.target_id == Context.snapshot(turn_id).id

    rollback =
      capture_log([metadata: [:event]], fn ->
        assert {:error, :test_rollback} =
                 Ledger.transaction(fn ->
                   Marshall.AgentContextRecoveryFixture.install_checkpoint(turn_id)
                   Ledger.rollback(:test_rollback)
                 end)
      end)

    refute rollback =~ "agent.context_published"
    assert Ledger.read!(ContextCheckpoint, turn_id: turn_id) == []
    assert Ledger.read!(AuditEvent, turn_id: turn_id, kind: :context_compacted) == []

    committed =
      capture_log([metadata: [:event, :kind]], fn ->
        Marshall.AgentContextRecoveryFixture.install_checkpoint(turn_id)
      end)

    assert committed =~ "kind=context_compacted"
    refute committed =~ "Recovered compacted context"
    assert [checkpoint] = Ledger.read!(ContextCheckpoint, turn_id: turn_id)
    assert [receipt] = Ledger.read!(AuditEvent, turn_id: turn_id, kind: :context_compacted)
    assert receipt.target_id == checkpoint.id
    assert receipt.actor_id == owner.id
  end
end
