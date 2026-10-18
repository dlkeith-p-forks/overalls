defmodule Marshall.Compute.RetryMeasurementWindowHistoryTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures

  alias Marshall.Compute.{
    Ledger,
    LifecycleEvent,
    NetworkAddress,
    Operation,
    PhysicalOutcome,
    Relocation,
    RelocationRetry,
    Reservation,
    ServiceLevelTotal,
    SourcePermitRequest,
    VirtualMachine,
    WorkflowServiceLevelAttempt,
    WorkflowServiceLevels,
    WorkloadPlacement
  }

  @moduletag timeout: 900_000
  @duration_bounds [
    1_000_000,
    5_000_000,
    10_000_000,
    30_000_000,
    120_000_000,
    600_000_000,
    3_000_000_000
  ]
  @type context :: %{
          vm: VirtualMachine.t(),
          owner: Marshall.Accounts.User.t(),
          relocation: Relocation.t(),
          retry: RelocationRetry.t(),
          start: Operation.t(),
          earlier: Operation.t(),
          measurement: WorkflowServiceLevelAttempt.t()
        }
  @type presence :: :none | :physical | :both
  @type binding ::
          :valid
          | :operation
          | :vm
          | :placement
          | :epoch
          | :generation
          | :ready_operation
          | :ready_generation
          | :ready_workflow
          | :ready_historical

  test "historical retry lookup requires current permission and changes no execution authority" do
    sandbox(fn ->
      c = historical_fixture()
      foreign = user()
      retained = inventory()
      params = %{relocation_id: c.relocation.id, idempotency_key: c.retry.request_key}
      assert {:ok, receipt} = Marshall.Compute.retry_relocation(params, actor: c.owner)
      assert receipt.id == c.retry.id
      assert {:error, _} = Marshall.Compute.retry_relocation(params, actor: foreign)

      assert {:error, error} =
               Marshall.Compute.retry_relocation(
                 %{params | idempotency_key: Ash.UUID.generate()},
                 actor: c.owner
               )

      assert Exception.message(error) =~ "relocation_retry_unavailable"
      assert inventory() == retained
    end)
  end

  # @cc [owner:ghuntley,label:verification;accounting] retry-two-proof-window-history
  # Historical retry measurements MUST require both exact received proofs inside
  # their immutable admission/deadline window. Missing, early, late or future
  # evidence MUST NOT fabricate success. Repeated scans retain one terminal row
  # and exact totals without mutating authority, receipts or proof inventories.
  # Fixtures import old stop/start history directly; they never admit or execute
  # a current cold retry. Timestamp edits only model received evidence time.
  property "historical retry measurements retain both proof windows through repeated scans",
    test_cases: 4,
    seed: 2_026_101_807 do
    physical = draw("physical receipt offset", member_of([-1, 0, 599, 600, 601]))
    ready = draw("ready receipt offset", member_of([-1, 0, 599, 600, 601]))
    phase = draw("scan before or after deadline", member_of([:before, :after]))
    presence = draw("present historical proofs", member_of([:none, :physical, :both]))
    repeats = draw("repeated database scans", integer(1..4))

    for witness <- [
          {physical, ready, phase, presence},
          {-1, 0, :after, :both},
          {0, 0, :after, :both},
          {599, 600, :after, :both},
          {600, 600, :after, :both},
          {600, 601, :after, :both},
          {600, 600, :before, :both},
          {0, 600, :before, :both},
          {600, 0, :before, :both},
          {0, -1, :after, :both},
          {601, 0, :after, :both},
          {0, 0, :after, :none},
          {0, 0, :after, :physical},
          {0, 0, :before, :none},
          {0, 0, :before, :physical}
        ] do
      sandbox(fn -> window_history(witness, repeats) end)
    end
  end

  @spec window_history({integer(), integer(), :before | :after, presence()}, pos_integer()) :: :ok
  defp window_history({physical, ready, phase, presence}, repeats) do
    c = historical_fixture()
    anchor = DateTime.add(Ledger.now(), if(phase == :before, do: -300, else: -601))
    set_window(c.measurement, anchor)
    if presence != :none, do: physical!(c, c.start, 1, DateTime.add(anchor, physical))
    if presence == :both, do: ready!(c, DateTime.add(anchor, ready))
    inventory = inventory()
    [before] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)
    now = Ledger.now()

    valid =
      presence == :both and physical in 0..600 and ready in 0..600 and
        DateTime.compare(DateTime.add(anchor, max(physical, ready)), now) != :gt

    expected =
      cond do
        valid -> :succeeded
        phase == :after -> :failed
        true -> :pending
      end

    {row, total} =
      Enum.reduce(1..repeats, nil, fn scan, prior ->
        count = if scan == 1 and expected != :pending, do: 1, else: 0
        assert {:ok, ^count} = WorkflowServiceLevels.reconcile()
        [row] = Ledger.read!(WorkflowServiceLevelAttempt, id: c.measurement.id)
        [total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)
        assert row.admitted_at == anchor and row.deadline == DateTime.add(anchor, 600)
        assert inventory() == inventory

        if expected == :pending do
          assert row.status == :pending and row.completed_at == nil and row.success == nil
          assert total == before
        else
          success = expected == :succeeded
          seconds = if success, do: max(physical, ready), else: 600
          assert row.status == :finished and row.success == success
          assert row.completed_at == DateTime.add(anchor, seconds)
          assert row.duration_us == seconds * 1_000_000
          assert total.requests == before.requests + 1
          assert total.successes == before.successes + if(success, do: 1, else: 0)
          assert total.failures == before.failures + if(success, do: 0, else: 1)

          bucket =
            Enum.find_index(@duration_bounds, &(seconds * 1_000_000 <= &1)) ||
              length(@duration_bounds)

          assert total.bucket_counts == List.update_at(before.bucket_counts, bucket, &(&1 + 1))
          assert total.duration_sum_us == before.duration_sum_us + seconds * 1_000_000
          assert total.id == before.id and total.started_at == before.started_at
          if prior, do: assert(prior == {row, total})
        end

        {row, total}
      end)

    if expected == :failed and presence != :both do
      if presence == :none, do: physical!(c, c.start, 2, Ledger.now())
      ready!(c, Ledger.now())
      late_inventory = inventory()
      assert {:ok, 0} = WorkflowServiceLevels.reconcile()
      assert [row] == Ledger.read!(WorkflowServiceLevelAttempt, id: row.id)
      assert [total] == Ledger.read!(ServiceLevelTotal, service: :porsche_retry)
      assert inventory() == late_inventory
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification;security] historical-retry-proof-bindings
  # Historical measurement readers MUST revalidate operation/VM/placement/epoch/
  # generation identity and readiness workflow/generation bindings. An older
  # activation's evidence MUST NOT satisfy its newer retry. These deliberately
  # damaged archived observations exercise the reader, not protocol admission.
  property "historical retry readers refuse mismatched archived proof bindings",
    test_cases: 2,
    seed: 2_026_101_808 do
    selected =
      draw(
        "archived proof binding",
        member_of([
          :valid,
          :operation,
          :vm,
          :placement,
          :epoch,
          :generation,
          :ready_operation,
          :ready_generation,
          :ready_workflow,
          :ready_historical
        ])
      )

    repeats = draw("repeated refusal scans", integer(1..4))

    for binding <- [
          selected,
          :valid,
          :operation,
          :vm,
          :placement,
          :epoch,
          :generation,
          :ready_operation,
          :ready_generation,
          :ready_workflow,
          :ready_historical
        ] do
      sandbox(fn -> binding_history(binding, repeats) end)
    end
  end

  @spec binding_history(binding(), pos_integer()) :: :ok
  defp binding_history(binding, repeats) do
    c = historical_fixture()
    anchor = DateTime.add(Ledger.now(), -30)
    set_window(c.measurement, anchor)
    at = DateTime.add(anchor, 1)
    physical!(c, c.start, 1, at, binding)
    ready!(c, at, binding)
    retained = inventory()
    [before] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)

    for scan <- 1..repeats do
      count = if binding == :valid and scan == 1, do: 1, else: 0
      assert {:ok, ^count} = WorkflowServiceLevels.reconcile()
      [row] = Ledger.read!(WorkflowServiceLevelAttempt, id: c.measurement.id)
      [total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)

      if binding == :valid do
        assert row.status == :finished and row.success
        assert total.requests == before.requests + 1 and total.successes == before.successes + 1
      else
        assert row.status == :pending and row.completed_at == nil and row.success == nil
        assert total == before
      end

      assert inventory() == retained
    end

    :ok
  end

  property "older archived activation proof cannot replace the retry proof",
    test_cases: 8,
    seed: 2_026_101_809 do
    repeats = draw("old proof scans", integer(1..4))

    sandbox(fn ->
      c = historical_fixture()
      anchor = DateTime.add(Ledger.now(), -30)
      set_window(c.measurement, anchor)
      physical!(c, c.earlier, 1, DateTime.add(anchor, 1))
      ready!(c, DateTime.add(anchor, 1))
      retained = inventory()
      for _ <- 1..repeats, do: assert({:ok, 0} == WorkflowServiceLevels.reconcile())

      assert [%{status: :pending}] =
               Ledger.read!(WorkflowServiceLevelAttempt, id: c.measurement.id)

      assert inventory() == retained
      physical!(c, c.start, 2, DateTime.add(anchor, 2))
      assert {:ok, 1} = WorkflowServiceLevels.reconcile()

      assert [%{status: :finished, success: true, duration_us: 2_000_000}] =
               Ledger.read!(WorkflowServiceLevelAttempt, id: c.measurement.id)

      after_success = inventory()
      for _ <- 1..repeats, do: assert({:ok, 0} == WorkflowServiceLevels.reconcile())
      assert inventory() == after_success
    end)
  end

  # Import a typed pre-upgrade history without invoking current lifecycle or
  # relocation admission. No outbox job is run and no guest protocol is called.
  @spec historical_fixture() :: context()
  defp historical_fixture do
    source = host_fixture()
    owner = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
    destination = host_fixture()

    target =
      Ledger.create!(WorkloadPlacement, :allocate, %{
        vm_id: vm.id,
        host_id: destination.host.id,
        pool_id: destination.pool.id
      })

    Ledger.create!(Reservation, :reserve, %{
      vm_id: vm.id,
      placement_id: target.id,
      host_id: destination.host.id,
      pool_id: destination.pool.id,
      vcpu: vm.vcpu,
      memory_bytes: vm.memory_bytes,
      disk_bytes: vm.disk_bytes
    })

    relocation =
      Ledger.create!(Relocation, :record, %{
        vm_id: vm.id,
        source_placement_id: vm.current_placement_id,
        destination_placement_id: target.id,
        source_host_id: source.host.id,
        destination_host_id: destination.host.id,
        source_epoch: vm.execution_epoch,
        destination_epoch: vm.execution_epoch + 1,
        original_state: :running,
        preserves_memory: false,
        requested_by_id: owner.id,
        source_endpoint: transfer_endpoint(),
        request_key: Ash.UUID.generate()
      })

    [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)

    intent = %{
      relocation_id: relocation.id,
      vm_id: vm.id,
      source: %{
        placement_id: vm.current_placement_id,
        host_id: source.host.id,
        pool_id: source.pool.id
      },
      destination: %{
        placement_id: target.id,
        host_id: destination.host.id,
        pool_id: destination.pool.id
      },
      source_epoch: relocation.source_epoch,
      destination_epoch: relocation.destination_epoch,
      workload:
        Map.merge(
          Map.take(vm, [:image_id, :architecture, :profile, :vcpu, :memory_bytes, :disk_bytes]),
          %{slot: address.slot}
        )
    }

    descriptor = Map.put(intent, :stream, %{source_dataset_guid: "100", to_guid: "201"})

    request = %{
      id: Ash.UUID.generate(),
      intent: intent,
      generation: vm.generation,
      public_key: transfer_endpoint()["host_key"],
      revision: 1,
      expires_at: System.system_time(:second) + 180,
      to_guid: nil
    }

    imported =
      Ledger.create!(SourcePermitRequest, :enqueue, %{
        id: request.id,
        relocation_id: relocation.id,
        source_host_id: source.host.id,
        revision: 1,
        request: OverallsProtocol.RelocationSource.encode_command(request)
      })

    imported =
      Ledger.update!(imported, :record_result, %{
        descriptor: OverallsProtocol.Relocation.encode_descriptor(descriptor)
      })

    earlier = historical_operation!(vm, relocation, target, vm.generation + 1, :start)

    relocation =
      Ledger.update!(relocation, :record_key, %{
        destination_public_key: transfer_endpoint()["host_key"]
      })

    relocation = Ledger.update!(relocation, :begin_copy, %{})
    relocation = Ledger.update!(relocation, :begin_import, %{})
    relocation = Ledger.update!(relocation, :confirm_import, %{})

    relocation =
      Ledger.update!(relocation, :record_commit, %{
        committed_at: Ledger.now(),
        import_request_id: imported.id,
        activation_operation_id: earlier.id,
        activation_generation: earlier.generation
      })

    stop = historical_operation!(vm, relocation, target, earlier.generation + 1, :stop)
    start = historical_operation!(vm, relocation, target, stop.generation + 1, :start)

    retry =
      Ash.Seed.seed!(RelocationRetry, %{
        id: Ash.UUID.generate(),
        relocation_id: relocation.id,
        vm_id: vm.id,
        requested_by_id: owner.id,
        request_key: Ash.UUID.generate(),
        stop_operation_id: stop.id,
        stop_generation: stop.generation,
        status: :activated,
        start_operation_id: start.id,
        start_generation: start.generation,
        finished_at: Ledger.now()
      })

    receipt =
      Ledger.create!(Marshall.SSH.Request, :record, %{
        request_id: Ash.UUID.generate(),
        user_id: owner.id,
        vm_id: vm.id,
        relocation_id: relocation.id,
        relocation_retry_id: retry.id,
        status: :accepted,
        result: %{},
        command: %{"command" => "request retry"},
        measurement_started_at: Ledger.now()
      })

    [measurement] = Ledger.read!(WorkflowServiceLevelAttempt, request_id: receipt.id)

    %{
      vm: vm,
      owner: owner,
      relocation: relocation,
      retry: retry,
      start: start,
      earlier: earlier,
      measurement: measurement
    }
  end

  @spec historical_operation!(
          VirtualMachine.t(),
          Relocation.t(),
          WorkloadPlacement.t(),
          pos_integer(),
          :start | :stop
        ) :: Operation.t()
  defp historical_operation!(vm, r, placement, generation, kind),
    do:
      Ledger.create!(Operation, :enqueue, %{
        vm_id: vm.id,
        placement_id: placement.id,
        execution_epoch: r.destination_epoch,
        generation: generation,
        kind: kind,
        initiator: :relocation,
        relocation_id: r.id
      })

  @spec physical!(context(), Operation.t(), pos_integer(), DateTime.t(), binding()) ::
          PhysicalOutcome.t()
  defp physical!(c, operation, sequence, at, binding \\ :valid) do
    observation = %{
      id: Ash.UUID.generate(),
      operation_id: operation.id,
      vm_id: operation.vm_id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      generation: operation.generation,
      sequence: sequence,
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    observation =
      case binding do
        :operation -> %{observation | operation_id: c.earlier.id}
        :vm -> %{observation | vm_id: Ash.UUID.generate()}
        :placement -> %{observation | placement_id: Ash.UUID.generate()}
        :epoch -> %{observation | execution_epoch: observation.execution_epoch + 1}
        :generation -> %{observation | generation: observation.generation + 1}
        _ -> observation
      end

    encoded = OverallsProtocol.Execution.encode_outcome(observation)
    assert {:ok, ^observation} = OverallsProtocol.Execution.outcome(encoded)

    row =
      Ledger.create!(PhysicalOutcome, :record, %{
        id: observation.id,
        operation_id: operation.id,
        vm_id: operation.vm_id,
        placement_id: operation.placement_id,
        execution_epoch: operation.execution_epoch,
        generation: operation.generation,
        host_id: c.relocation.destination_host_id,
        sequence: sequence,
        observation: encoded
      })

    received_time("compute_physical_outcomes", row.id, at)
    row
  end

  @spec ready!(context(), DateTime.t(), binding()) :: LifecycleEvent.t()
  defp ready!(c, at, binding \\ :valid) do
    id = if binding in [:ready_operation, :ready_historical], do: c.earlier.id, else: c.start.id

    generation =
      if binding == :ready_generation, do: c.start.generation + 1, else: c.start.generation

    workflow = if binding == :ready_workflow, do: Ash.UUID.generate(), else: c.relocation.id

    event =
      Ledger.create!(LifecycleEvent, :record, %{
        actor_kind: :system,
        resource_type: "ReadinessRequest",
        resource_id: id,
        action: "ready",
        vm_id: c.vm.id,
        workflow_id: workflow,
        operation_id: id,
        generation: generation,
        measurement_outcome: :succeeded,
        occurred_at: Ledger.now(),
        expires_at: DateTime.add(Ledger.now(), 90, :day)
      })

    received_time("compute_lifecycle_events", event.id, at)
    event
  end

  @spec set_window(WorkflowServiceLevelAttempt.t(), DateTime.t()) :: :ok
  defp set_window(measurement, anchor) do
    assert %{num_rows: 1} =
             Marshall.Repo.query!(
               "UPDATE compute_workflow_service_level_attempts SET admitted_at=$1, deadline=$2 WHERE id=$3",
               [
                 DateTime.to_naive(anchor),
                 DateTime.to_naive(DateTime.add(anchor, 600)),
                 Ecto.UUID.dump!(measurement.id)
               ],
               log: false
             )

    :ok
  end

  @spec received_time(String.t(), String.t(), DateTime.t()) :: :ok
  defp received_time(table, id, at)
       when table in ["compute_physical_outcomes", "compute_lifecycle_events"] do
    assert %{num_rows: 1} =
             Marshall.Repo.query!(
               "UPDATE #{table} SET inserted_at=$1 WHERE id=$2",
               [DateTime.to_naive(at), Ecto.UUID.dump!(id)],
               log: false
             )

    :ok
  end

  @spec inventory() :: [list(struct())]
  defp inventory,
    do:
      Enum.map(
        [
          VirtualMachine,
          Relocation,
          RelocationRetry,
          Operation,
          WorkloadPlacement,
          Reservation,
          PhysicalOutcome,
          LifecycleEvent,
          SourcePermitRequest,
          Marshall.Compute.Host,
          Marshall.Compute.StoragePool,
          Marshall.SSH.Request
        ],
        fn resource ->
          Enum.sort_by(Ledger.read!(resource), & &1.id)
        end
      )

  @spec sandbox((-> :ok | true)) :: :ok | true
  defp sandbox(function) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)

    try do
      function.()
    after
      :ok = Ecto.Adapters.SQL.Sandbox.checkin(Marshall.Repo)
    end
  end
end
