defmodule Marshall.Compute.ServiceLevelsTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Compute.{
    Ledger,
    Operation,
    ServiceLevelAttempt,
    ServiceLevelTotal,
    ServiceLevelPublisher,
    ServiceLevels
  }

  alias Marshall.ComputeFixtures, as: Fixtures

  @origin ~U[2026-10-02 00:00:00.000000Z]

  # @cc [owner:ghuntley,label:verification;accounting] suspension-measurements-use-physical-states
  # Pause MUST complete only from paused evidence and resume only from running
  # evidence. SSH resume additionally requires readiness; intent alone and the
  # other operation's physical state MUST remain pending before the deadline.
  property "pause and resume measurement states remain distinct",
    test_cases: 32,
    seed: 2_026_101_805 do
    kind = draw("suspension operation", member_of([:pause, :resume]))
    offset = draw("physical evidence seconds", integer(1..60))
    at = DateTime.add(@origin, offset)
    deadline = DateTime.add(@origin, 120)
    expected = if kind == :pause, do: :paused, else: :running
    other = if kind == :pause, do: :running, else: :paused
    physical = %{state: expected, at: at}

    assert {:finished, true, ^at, duration} =
             ServiceLevels.decide(:lilly_physical, kind, @origin, deadline, physical, nil, at)

    assert duration == offset * 1_000_000

    assert :pending =
             ServiceLevels.decide(
               :lilly_physical,
               kind,
               @origin,
               deadline,
               %{physical | state: other},
               nil,
               at
             )

    if kind == :resume do
      assert :pending =
               ServiceLevels.decide(:porsche_physical, kind, @origin, deadline, physical, nil, at)

      assert {:finished, true, ^at, _} =
               ServiceLevels.decide(:porsche_physical, kind, @origin, deadline, physical, at, at)
    end
  end

  test "retained paused evidence completes a physical pause measurement" do
    Fixtures.host_fixture()
    actor = Fixtures.user()
    assert {:ok, vm} = Marshall.Compute.provision(Fixtures.request(), actor: actor)

    operation =
      Ledger.create!(Operation, :enqueue, %{
        vm_id: vm.id,
        placement_id: vm.current_placement_id,
        execution_epoch: vm.execution_epoch,
        generation: vm.generation + 1,
        kind: :pause,
        requested_by_id: actor.id
      })

    checkpoint = %{
      id: Ash.UUID.generate(),
      memory_bytes: vm.memory_bytes,
      state_bytes: 4096,
      compatibility: "sha256:" <> String.duplicate("a", 64),
      memory_sha256: "sha256:" <> String.duplicate("b", 64),
      state_sha256: "sha256:" <> String.duplicate("c", 64),
      manifest_sha256: "sha256:" <> String.duplicate("d", 64),
      dataset_guid: "81",
      snapshot_guid: "82"
    }

    outcome = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: 1,
      state: :paused,
      compute_empty: true,
      disk_present: true,
      cleanup_complete: false,
      reason: :none,
      checkpoint: checkpoint
    }

    Ledger.create!(Marshall.Compute.PhysicalOutcome, :record, %{
      id: outcome.id,
      vm_id: vm.id,
      host_id: vm.host_id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: 1,
      observation: OverallsProtocol.Execution.encode_outcome(outcome)
    })

    assert {:ok, 1} = ServiceLevels.reconcile()

    assert [%{status: :finished, success: true}] =
             Ledger.read!(ServiceLevelAttempt, operation_id: operation.id)

    assert {:ok, 0} = ServiceLevels.reconcile()
  end

  property "deadline histories never manufacture success from missing or late readiness" do
    check all(
            budget <- integer(1..3_000),
            physical_offset <- integer(0..4_000),
            ready_offset <- integer(0..4_000),
            observed_offset <- integer(0..4_000)
          ) do
      deadline = DateTime.add(@origin, budget)
      physical_at = DateTime.add(@origin, physical_offset)
      ready_at = DateTime.add(@origin, ready_offset)
      now = DateTime.add(@origin, observed_offset)
      physical = %{state: :running, at: physical_at}

      result =
        ServiceLevels.decide(
          :marshall_ready,
          :provision,
          @origin,
          deadline,
          physical,
          ready_at,
          now
        )

      cond do
        physical_offset <= budget and ready_offset <= budget ->
          assert {:finished, true, at, duration} = result
          assert at == DateTime.add(@origin, max(physical_offset, ready_offset))
          assert duration == max(physical_offset, ready_offset) * 1_000_000

        observed_offset >= budget ->
          assert result == {:finished, false, deadline, budget * 1_000_000}

        true ->
          assert result == :pending
      end

      missing =
        ServiceLevels.decide(:marshall_ready, :provision, @origin, deadline, physical, nil, now)

      if observed_offset < budget,
        do: assert(missing == :pending),
        else: assert(missing == {:finished, false, deadline, budget * 1_000_000})
    end
  end

  property "missing physical evidence survives observation histories until the deadline" do
    check all(
            budget <- integer(1..3_000),
            offsets <- list_of(integer(-1_000..4_000), min_length: 1)
          ) do
      deadline = DateTime.add(@origin, budget)

      for offset <- offsets do
        result =
          ServiceLevels.decide(
            :lilly_physical,
            :start,
            @origin,
            deadline,
            nil,
            nil,
            DateTime.add(@origin, offset)
          )

        if offset < budget,
          do: assert(result == :pending),
          else: assert(result == {:finished, false, deadline, budget * 1_000_000})
      end
    end
  end

  test "actual admission is atomic and request replay does not add measurements" do
    Fixtures.host_fixture()
    actor = Fixtures.user()
    request = Fixtures.request()

    assert {:ok, vm} = Marshall.Compute.provision(request, actor: actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id, kind: :provision)
    attempts = Ledger.read!(ServiceLevelAttempt, operation_id: operation.id)
    assert Enum.sort(Enum.map(attempts, & &1.service)) == [:lilly_physical, :marshall_ready]
    [ready] = Enum.filter(attempts, &(&1.service == :marshall_ready))
    assert DateTime.diff(ready.deadline, ready.admitted_at) == 120
    assert Enum.all?(attempts, &(&1.status == :pending and &1.success == nil))
    assert {:ok, replay} = Marshall.Compute.provision(request, actor: actor)
    assert replay.id == vm.id

    assert Enum.sort(
             Enum.map(Ledger.read!(ServiceLevelAttempt, operation_id: operation.id), & &1.id)
           ) ==
             Enum.sort(Enum.map(attempts, & &1.id))

    assert {:ok, 0} = ServiceLevels.reconcile()
  end

  test "physical running alone does not complete creation readiness or refresh receipts" do
    Fixtures.host_fixture()
    actor = Fixtures.user()
    assert {:ok, vm} = Marshall.Compute.provision(Fixtures.request(), actor: actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id, kind: :provision)

    outcome_id = Ash.UUID.generate()

    observation = %{
      id: outcome_id,
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

    Ledger.create!(Marshall.Compute.PhysicalOutcome, :record, %{
      id: outcome_id,
      host_id: operation.command_snapshot["host_id"],
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: 1,
      observation: OverallsProtocol.Execution.encode_outcome(observation)
    })

    assert {:ok, 1} = ServiceLevels.reconcile()

    [physical] =
      Ledger.read!(ServiceLevelAttempt, operation_id: operation.id, service: :lilly_physical)

    [ready] =
      Ledger.read!(ServiceLevelAttempt, operation_id: operation.id, service: :marshall_ready)

    assert physical.status == :finished and physical.success
    assert ready.status == :pending
    [unchanged] = Ledger.read!(Operation, id: operation.id)
    assert unchanged.status == :pending
    assert {:ok, 0} = ServiceLevels.reconcile()
    [totals] = Ledger.read!(ServiceLevelTotal, service: :lilly_physical)
    assert totals.requests == 1 and totals.successes == 1 and totals.failures == 0
    assert Enum.sum(totals.bucket_counts) == 1

    now = Ledger.now()

    event = %{
      actor_kind: :system,
      resource_type: "Provisioning",
      resource_id: Ash.UUID.generate(),
      action: "mark_ready",
      next_state: "ready",
      vm_id: vm.id,
      host_id: operation.command_snapshot["host_id"],
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      generation: operation.generation + 1,
      occurred_at: now,
      expires_at: DateTime.add(now, 90, :day)
    }

    Ledger.create!(Marshall.Compute.LifecycleEvent, :record, event)
    assert {:ok, 0} = ServiceLevels.reconcile()

    Ledger.create!(Marshall.Compute.LifecycleEvent, :record, %{
      event
      | generation: operation.generation
    })

    assert {:ok, 0} = ServiceLevels.reconcile()
    ready_id = Ash.UUID.generate()

    ready_observation =
      observation
      |> Map.put(:id, ready_id)
      |> Map.put(:sequence, 2)
      |> Map.put(:guest_ready, true)

    Ledger.create!(Marshall.Compute.PhysicalOutcome, :record, %{
      id: ready_id,
      host_id: operation.command_snapshot["host_id"],
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: 2,
      observation: OverallsProtocol.Execution.encode_outcome(ready_observation)
    })

    assert {:ok, 1} = ServiceLevels.reconcile()

    [ready] =
      Ledger.read!(ServiceLevelAttempt, operation_id: operation.id, service: :marshall_ready)

    assert ready.status == :finished and ready.success
    assert {:ok, 0} = ServiceLevels.reconcile()
    [ready_totals] = Ledger.read!(ServiceLevelTotal, service: :marshall_ready)
    assert ready_totals.requests == 1 and ready_totals.successes == 1
    assert Enum.sum(ready_totals.bucket_counts) == 1

    receipts =
      for _ <- 1..2 do
        Ledger.create!(Marshall.SSH.Request, :record, %{
          request_id: Ash.UUID.generate(),
          user_id: actor.id,
          command: %{},
          vm_id: vm.id,
          operation_id: operation.id,
          status: :accepted,
          result: %{}
        })
      end

    [ssh_attempt] =
      Ledger.read!(ServiceLevelAttempt, operation_id: operation.id, service: :porsche_physical)

    assert ssh_attempt.admitted_at == physical.admitted_at
    assert ssh_attempt.deadline == physical.deadline
    assert {:ok, 1} = ServiceLevels.reconcile()
    [ssh_totals] = Ledger.read!(ServiceLevelTotal, service: :porsche_physical)
    assert ssh_totals.requests == 1 and ssh_totals.successes == 1

    for receipt <- receipts do
      [unchanged_receipt] = Ledger.read!(Marshall.SSH.Request, id: receipt.id)
      assert unchanged_receipt.status == :accepted
    end

    assert_raise Ash.Error.Invalid, fn ->
      Ledger.update!(ready, :finish, %{success: false, completed_at: now, duration_us: 0})
    end
  end

  test "failed outer admission leaves neither operations nor reliability rows" do
    Fixtures.host_fixture()
    actor = Fixtures.user()
    request = Fixtures.request()
    sources_before = Ledger.read!(ServiceLevelTotal, [])

    assert {:error, :test_rollback} =
             Ledger.transaction(fn ->
               assert {:ok, _} = Marshall.Compute.provision(request, actor: actor)
               Ledger.rollback(:test_rollback)
             end)

    assert Ledger.read!(ServiceLevelAttempt, []) == []
    assert Ledger.read!(ServiceLevelTotal, []) == sources_before
    assert Ledger.read!(Operation, []) == []
  end

  # @cc [owner:ghuntley,label:verification;accounting] overdue-backlog-test-isolation
  # Synthetic deadlines MUST be changed only in this sandbox-owned fixture.
  # The test MUST inspect real bounded reconciliation and permanent totals,
  # without dispatching provider work or waiting for wall-clock expiry.
  test "an overdue backlog withholds publication until every expired admission is counted" do
    Fixtures.host_fixture()
    actor = Fixtures.user()
    assert {:ok, vm} = Marshall.Compute.provision(Fixtures.request(), actor: actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id, kind: :provision)

    for generation <- 2..51 do
      Ledger.create!(Operation, :enqueue, %{
        vm_id: vm.id,
        placement_id: operation.placement_id,
        execution_epoch: operation.execution_epoch,
        requested_by_id: actor.id,
        generation: generation,
        kind: :provision,
        request_key: Ash.UUID.generate()
      })
    end

    directory = Path.join(System.tmp_dir!(), "slo-backlog-#{Ash.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    assert :ok = ServiceLevelPublisher.publish(directory)
    path = Path.join(directory, "lilly_physical.json")
    before_backlog = File.read!(path)

    assert %{num_rows: 102} =
             Ecto.Adapters.SQL.query!(
               Marshall.Repo,
               "UPDATE compute_service_level_attempts SET admitted_at = $1, deadline = $2",
               [DateTime.to_naive(@origin), DateTime.to_naive(DateTime.add(@origin, 1))],
               log: false
             )

    assert :error = ServiceLevelPublisher.publish(directory)
    assert File.read!(path) == before_backlog
    totals = Ledger.read!(ServiceLevelTotal, [])
    assert Enum.sum(Enum.map(totals, & &1.requests)) == 100
    assert Enum.all?(totals, &(&1.requests == &1.failures and &1.successes == 0))
    assert :ok = ServiceLevelPublisher.publish(directory)
    totals = Ledger.read!(ServiceLevelTotal, [])
    assert Enum.sum(Enum.map(totals, & &1.requests)) == 102
    assert Enum.all?(totals, &(Enum.sum(&1.bucket_counts) == &1.requests))
    assert Enum.all?(Ledger.read!(Operation, vm_id: vm.id), &(&1.status == :pending))
    assert {:ok, 0} = ServiceLevels.reconcile()
  end
end
