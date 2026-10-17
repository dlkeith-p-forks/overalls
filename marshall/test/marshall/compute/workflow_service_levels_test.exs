defmodule Marshall.Compute.WorkflowServiceLevelsTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  alias Marshall.Compute
  alias Marshall.ComputeFixtures, as: Fixtures

  alias Marshall.Compute.{
    CloneRequest,
    Ledger,
    LifecycleEvent,
    Operation,
    ServiceLevelTotal,
    WorkflowServiceLevelAttempt,
    WorkflowServiceLevels
  }

  @origin ~U[2026-10-02 10:00:00Z]

  property "temporal histories refuse pre-admission late future and wrong-disposition evidence" do
    check all(
            expected <- member_of([:succeeded, :cancelled]),
            outcome <- member_of([:succeeded, :failed, :cancelled, :superseded]),
            offset <- integer(-600..1_200),
            now <- integer(0..1_600)
          ) do
      deadline = DateTime.add(@origin, 600)
      evidence = %{outcome: outcome, at: DateTime.add(@origin, offset)}

      decision =
        WorkflowServiceLevels.decide(
          expected,
          @origin,
          deadline,
          evidence,
          DateTime.add(@origin, now)
        )

      cond do
        offset in 0..600 and offset <= now ->
          if outcome == :superseded or (expected == :succeeded and outcome == :cancelled),
            do: assert(decision == {:excluded, outcome, evidence.at, offset * 1_000_000}),
            else:
              assert(
                decision == {:finished, outcome == expected, evidence.at, offset * 1_000_000}
              )

        now >= 600 ->
          assert decision == {:finished, false, deadline, 600_000_000}

        true ->
          assert decision == :pending
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] same-sequence-workflow-history
  # The test MUST retain a failed measurement and its terminal audit evidence
  # when source-restoration retry reuses the clone sequence. A wrong sequence
  # MUST stay pending; only new matching evidence may complete the new receipt.
  property "restoration retries retain failed history without accepting another clone sequence" do
    {owner, vm, clone} = clone_fixture()

    check all(wrong_delta <- integer(1..100), max_runs: 12) do
      original = receipt(owner, vm, clone, "clone", Ledger.now())
      clone = Ledger.update!(clone, :record_progress, %{failure: "source_restart_failed"})
      assert {:ok, 1} = WorkflowServiceLevels.reconcile()
      [first] = Ledger.read!(WorkflowServiceLevelAttempt, request_id: original.id)
      assert first.status == :finished and first.success == false
      prior = Ledger.read!(LifecycleEvent, resource_id: clone.id, measurement_outcome: :failed)
      assert Enum.any?(prior, &(&1.sequence == clone.sequence))

      start = Ledger.now()
      clone = Ledger.update!(clone, :record_progress, %{failure: "retry_source_restart"})
      retry = receipt(owner, vm, clone, "request retry", start)
      [pending] = Ledger.read!(WorkflowServiceLevelAttempt, request_id: retry.id)
      event(clone, clone.sequence + wrong_delta, :succeeded)
      assert {:ok, 0} = WorkflowServiceLevels.reconcile()
      [still_pending] = Ledger.read!(WorkflowServiceLevelAttempt, id: pending.id)
      assert still_pending.status == :pending

      event(clone, clone.sequence, :succeeded)
      assert {:ok, 1} = WorkflowServiceLevels.reconcile()
      [finished] = Ledger.read!(WorkflowServiceLevelAttempt, id: pending.id)
      assert finished.success and finished.deadline == pending.deadline
      assert Ledger.read!(WorkflowServiceLevelAttempt, id: first.id) == [first]
      assert Enum.all?(prior, &(&1 in Ledger.read!(LifecycleEvent, resource_id: clone.id)))
      assert {:ok, 0} = WorkflowServiceLevels.reconcile()
    end
  end

  test "synchronous cancellation is counted once and replay cannot reset its deadline" do
    {owner, vm, clone} = clone_fixture()
    before = source(:porsche_cancel)
    original_before = source(:porsche_clone)
    original = receipt(owner, vm, clone, "clone", Ledger.now())
    start = Ledger.now()
    assert {:ok, cancelled} = Compute.cancel_clone(%{request_id: clone.id}, actor: owner)
    assert cancelled.phase == :cancelled
    [cancelled_row] = Ledger.read!(CloneRequest, id: cancelled.id)
    receipt = receipt(owner, vm, cancelled_row, "request cancel", start)
    [attempt] = Ledger.read!(WorkflowServiceLevelAttempt, request_id: receipt.id)
    assert attempt.status == :finished and attempt.success
    assert DateTime.compare(attempt.admitted_at, attempt.completed_at) != :gt
    assert source(:porsche_cancel).requests == before.requests + 1
    assert {:ok, 1} = WorkflowServiceLevels.reconcile()
    [excluded] = Ledger.read!(WorkflowServiceLevelAttempt, request_id: original.id)
    assert excluded.status == :finished and excluded.excluded_outcome == :cancelled
    assert excluded.success == nil
    assert source(:porsche_clone) == original_before
    assert :ok = WorkflowServiceLevels.admit!(receipt)
    assert Ledger.read!(WorkflowServiceLevelAttempt, request_id: receipt.id) == [attempt]
    assert source(:porsche_cancel).requests == before.requests + 1
  end

  test "outer rollback removes the receipt and measurement without changing execution inventory" do
    {owner, vm, clone} = clone_fixture()
    before = Ledger.read!(Operation, vm_id: vm.id)
    id = Ash.UUID.generate()

    assert {:error, :fixture_rollback} =
             Ledger.transaction(fn ->
               receipt(owner, vm, clone, "clone", Ledger.now(), id)
               Ledger.rollback(:fixture_rollback)
             end)

    assert Ledger.read!(Marshall.SSH.Request, request_id: id) == []
    assert Ledger.read!(WorkflowServiceLevelAttempt, workflow_id: clone.id) == []
    assert Ledger.read!(Operation, vm_id: vm.id) == before
  end

  @spec clone_fixture() ::
          {Marshall.Accounts.User.t(), Compute.VirtualMachine.t(), CloneRequest.t()}
  defp clone_fixture do
    Fixtures.host_fixture()
    owner = Fixtures.user()
    {:ok, vm} = Compute.provision(Fixtures.request(), actor: owner)

    {:ok, result} =
      Compute.clone(%{vm_id: vm.id, idempotency_key: Ash.UUID.generate()}, actor: owner)

    [clone] = Ledger.read!(CloneRequest, id: result.id)
    {owner, vm, clone}
  end

  @spec receipt(
          Marshall.Accounts.User.t(),
          Compute.VirtualMachine.t(),
          CloneRequest.t(),
          String.t(),
          DateTime.t(),
          String.t()
        ) :: Marshall.SSH.Request.t()
  defp receipt(owner, vm, clone, command, started, id \\ Ash.UUID.generate()) do
    Ledger.create!(Marshall.SSH.Request, :record, %{
      request_id: id,
      user_id: owner.id,
      vm_id: vm.id,
      clone_request_id: clone.id,
      status: :accepted,
      result: %{},
      command: %{"command" => command},
      measurement_started_at: started
    })
  end

  @spec event(CloneRequest.t(), pos_integer(), WorkflowServiceLevels.outcome()) ::
          LifecycleEvent.t()
  defp event(clone, sequence, outcome) do
    now = Ledger.now()

    Ledger.create!(LifecycleEvent, :record, %{
      actor_kind: :system,
      resource_type: "CloneRequest",
      resource_id: clone.id,
      workflow_id: clone.id,
      action: "complete",
      next_state: "complete",
      sequence: sequence,
      measurement_outcome: outcome,
      occurred_at: now,
      expires_at: DateTime.add(now, 90, :day)
    })
  end

  @spec source(WorkflowServiceLevels.service()) :: ServiceLevelTotal.t()
  defp source(service), do: hd(Ledger.read!(ServiceLevelTotal, service: service))
end
