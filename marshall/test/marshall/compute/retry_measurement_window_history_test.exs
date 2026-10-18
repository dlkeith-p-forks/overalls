defmodule Marshall.Compute.RetryMeasurementWindowHistoryTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Compute

  alias Marshall.Compute.{
    Credentials,
    Host,
    HostReports,
    Ledger,
    LifecycleEvent,
    Operation,
    PhysicalOutcome,
    ReadinessRequest,
    Relocation,
    RelocationCoordinator,
    RelocationRetry,
    ServiceLevelTotal,
    VirtualMachine,
    WorkflowServiceLevelAttempt,
    WorkflowServiceLevels
  }

  # Four complete fifteen-window menus retain every temporal refusal witness.
  # Bound the complete database history without treating host load as a proof.
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

  # @cc [owner:ghuntley,label:verification;accounting] retry-two-proof-window-history
  # A retry measurement MUST require both exact received proofs within its
  # immutable admission/deadline window. Missing, pre-admission, late or future
  # evidence MUST NOT fabricate success. Repeated scans MUST retain one terminal
  # row and exact totals while preserving complete execution/receipt inventories.
  # Proofs use authenticated real actions; timestamp edits are sandbox-only
  # consumer controls, not elapsed clock, native boot or transport evidence.
  property "retry measurements retain both received proof windows through repeated scans",
    profile: :ci,
    test_cases: 4 do
    check all(
            physical <- member_of([-1, 0, 599, 600, 601]),
            ready <- member_of([-1, 0, 599, 600, 601]),
            phase <- member_of([:before, :after]),
            proofs <- member_of([:none, :physical, :both]),
            repeats <- member_of([1, 2, 4]),
            test_cases: 4
          ) do
      for {p, r, when_, presence} <- [
            {physical, ready, phase, proofs},
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
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)

        try do
          window_history(p, r, when_, presence, repeats)
        after
          :ok = Ecto.Adapters.SQL.Sandbox.checkin(Marshall.Repo)
        end
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;security] retry-proof-binding-refusal-history
  # Wrong immutable-operation or offered-readiness bindings MUST refuse through
  # authenticated actions without changing authority, proof, host or accounting
  # inventories. Matching proof after every refusal MUST still finish the exact
  # retry measurement once. Historical failed readiness MUST remain acknowledged
  # without satisfying the newer retry measurement.
  property "retry proof binding refusals conserve authority before matching success",
    test_cases: 2 do
    check all(
            binding <-
              member_of([
                :operation,
                :vm,
                :placement,
                :epoch,
                :generation,
                :host,
                :ready_operation,
                :ready_generation,
                :ready_descriptor,
                :ready_host,
                :ready_historical
              ]),
            repeats <- member_of([1, 2, 4]),
            test_cases: 2
          ) do
      for witness <- [
            binding,
            :operation,
            :vm,
            :placement,
            :epoch,
            :generation,
            :host,
            :ready_operation,
            :ready_generation,
            :ready_descriptor,
            :ready_host,
            :ready_historical
          ] do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)

        try do
          binding_history(witness, repeats)
        after
          :ok = Ecto.Adapters.SQL.Sandbox.checkin(Marshall.Repo)
        end
      end
    end
  end

  @type binding ::
          :operation
          | :vm
          | :placement
          | :epoch
          | :generation
          | :host
          | :ready_operation
          | :ready_generation
          | :ready_descriptor
          | :ready_host
          | :ready_historical

  @spec binding_history(binding(), pos_integer()) :: :ok
  defp binding_history(binding, repeats) do
    c = prepare_retry()
    [attempt] = Ledger.read!(WorkflowServiceLevelAttempt, id: c.measurement.id)
    [total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)
    initial_authority = authority()
    initial_proofs = proof_inventory()
    initial_hosts = Enum.sort_by(Ledger.read!(Host), & &1.id)
    initial_unrelated = unrelated_accounting(attempt.id, total.id)
    assert {:ok, 0} = WorkflowServiceLevels.reconcile()
    assert [initial_pending] = Ledger.read!(WorkflowServiceLevelAttempt, id: attempt.id)
    assert Map.delete(initial_pending, :checked_at) == Map.delete(attempt, :checked_at)
    assert authority() == initial_authority and proof_inventory() == initial_proofs
    assert Enum.sort_by(Ledger.read!(Host), & &1.id) == initial_hosts
    assert unrelated_accounting(attempt.id, total.id) == initial_unrelated
    assert [^total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)

    event = %{
      id: Ash.UUID.generate(),
      operation_id: c.start.id,
      vm_id: c.start.vm_id,
      placement_id: c.start.placement_id,
      execution_epoch: c.start.execution_epoch,
      generation: c.start.generation,
      sequence: 3,
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    readiness? =
      binding in [
        :ready_operation,
        :ready_generation,
        :ready_descriptor,
        :ready_host,
        :ready_historical
      ]

    if readiness?, do: ingest(c.channel, c.start, 3, :running)

    ready =
      if readiness? do
        assert {:ok, %{"commands" => [wire]}} = exchange(:ready, c.channel, [])
        assert {:ok, command} = OverallsProtocol.RelocationReadiness.command(wire)

        %{
          id: command.id,
          generation: command.generation,
          descriptor: command.descriptor,
          boot_id: Ash.UUID.generate()
        }
      end

    before_authority = authority()
    before_accounting = accounting_inventory()
    before_proofs = proof_inventory()
    before_hosts = Enum.sort_by(Ledger.read!(Host), & &1.id)
    [before_attempt] = Ledger.read!(WorkflowServiceLevelAttempt, id: attempt.id)

    for _ <- 1..repeats do
      if readiness? do
        refused =
          case binding do
            :ready_operation ->
              %{ready | id: c.old_ready.id}

            :ready_generation ->
              %{ready | generation: ready.generation + 1}

            :ready_descriptor ->
              %{ready | descriptor: %{ready.descriptor | relocation_id: Ash.UUID.generate()}}

            :ready_host ->
              ready

            :ready_historical ->
              c.old_ready
          end

        channel = if binding == :ready_host, do: c.source_channel, else: c.channel

        if binding == :ready_historical do
          assert {:ok, %{"acknowledgements" => [old_id]}} = exchange(:ready, channel, [refused])
          assert old_id == c.old_ready.id
        else
          assert {:error, :invalid_outcome} = exchange(:ready, channel, [refused])
        end
      else
        refused =
          case binding do
            :operation -> %{event | operation_id: c.relocation.activation_operation_id}
            :vm -> %{event | vm_id: Ash.UUID.generate()}
            :placement -> %{event | placement_id: Ash.UUID.generate()}
            :epoch -> %{event | execution_epoch: event.execution_epoch + 1}
            :generation -> %{event | generation: event.generation + 1}
            :host -> event
          end

        channel = if binding == :host, do: c.source_channel, else: c.channel

        assert {:ok, parsed} =
                 OverallsProtocol.Execution.outcome(
                   OverallsProtocol.Execution.encode_outcome(refused)
                 )

        assert {:error, :invalid_outcome} =
                 Compute.ProvisionerControl.exchange_execution(
                   channel.token,
                   %{
                     session_id: channel.session_id,
                     epoch: channel.epoch,
                     report: nil,
                     acknowledgements: [],
                     outcomes: [parsed]
                   }
                 )
      end

      assert authority() == before_authority
      assert accounting_inventory() == before_accounting
      assert proof_inventory() == before_proofs
      assert Enum.sort_by(Ledger.read!(Host), & &1.id) == before_hosts
      assert [^before_attempt] = Ledger.read!(WorkflowServiceLevelAttempt, id: attempt.id)
      assert [^total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)
    end

    if not readiness?, do: ingest(c.channel, c.start, 3, :running)

    valid_ready =
      if readiness? do
        ready
      else
        assert {:ok, %{"commands" => [wire]}} = exchange(:ready, c.channel, [])
        assert {:ok, command} = OverallsProtocol.RelocationReadiness.command(wire)

        %{
          id: command.id,
          generation: command.generation,
          descriptor: command.descriptor,
          boot_id: Ash.UUID.generate()
        }
      end

    assert {:ok, _} = exchange(:ready, c.channel, [valid_ready])
    assert [%{status: :ready}] = Ledger.read!(ReadinessRequest, id: c.start.id)
    before_finish_authority = authority()
    before_finish_proofs = proof_inventory()
    before_unrelated = unrelated_accounting(attempt.id, total.id)
    assert {:ok, 1} = WorkflowServiceLevels.reconcile()
    assert authority() == before_finish_authority
    assert proof_inventory() == before_finish_proofs
    assert unrelated_accounting(attempt.id, total.id) == before_unrelated
    [terminal] = Ledger.read!(WorkflowServiceLevelAttempt, id: attempt.id)
    assert terminal.status == :finished and terminal.success
    assert terminal.admitted_at == attempt.admitted_at and terminal.deadline == attempt.deadline
    [after_total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)

    assert after_total.requests == total.requests + 1 and
             after_total.successes == total.successes + 1

    assert after_total.failures == total.failures
    assert [running] = Ledger.read!(PhysicalOutcome, operation_id: c.start.id)

    assert [ready_event] =
             Ledger.read!(LifecycleEvent,
               resource_type: "ReadinessRequest",
               resource_id: c.start.id,
               measurement_outcome: :succeeded
             )

    assert ready_event.generation == c.start.generation and
             ready_event.workflow_id == c.relocation.id

    completed =
      Enum.max_by(
        [running.inserted_at, ready_event.inserted_at],
        &DateTime.to_unix(&1, :microsecond)
      )

    duration = DateTime.diff(completed, attempt.admitted_at, :microsecond)
    assert terminal.completed_at == completed and terminal.duration_us == duration
    bucket = Enum.find_index(@duration_bounds, &(duration <= &1)) || length(@duration_bounds)
    assert after_total.bucket_counts == List.update_at(total.bucket_counts, bucket, &(&1 + 1))
    assert after_total.duration_sum_us == total.duration_sum_us + duration
    assert after_total.id == total.id and after_total.started_at == total.started_at
    after_authority = authority()
    after_accounting = accounting_inventory()
    after_proofs = proof_inventory()

    for _ <- 1..repeats do
      assert {:ok, 0} = WorkflowServiceLevels.reconcile()
      assert [^terminal] = Ledger.read!(WorkflowServiceLevelAttempt, id: attempt.id)
      assert [^after_total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)
      assert authority() == after_authority and proof_inventory() == after_proofs
      assert accounting_inventory() == after_accounting
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification;recovery] retry-retained-historical-proof
  # Authenticated delayed physical receipts for exact older operations MUST be
  # retained without changing current intent or satisfying the newer retry.
  # Matching current proof MUST finish once; replay MUST conserve full totals.
  property "retained older physical proof cannot satisfy a newer retry measurement",
    test_cases: 2 do
    check all(
            side <- member_of([:source, :destination]),
            repeats <- member_of([1, 2, 4]),
            test_cases: 2
          ) do
      for endpoint <- [side, :source, :destination] do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)

        try do
          historical_history(endpoint, repeats)
        after
          :ok = Ecto.Adapters.SQL.Sandbox.checkin(Marshall.Repo)
        end
      end
    end
  end

  @spec historical_history(:source | :destination, pos_integer()) :: :ok
  defp historical_history(side, repeats) do
    c = prepare_retry()
    [attempt] = Ledger.read!(WorkflowServiceLevelAttempt, id: c.measurement.id)
    [total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)

    historical =
      case side do
        :source -> hd(Ledger.read!(Operation, vm_id: c.vm.id, kind: :provision))
        :destination -> hd(Ledger.read!(Operation, id: c.relocation.activation_operation_id))
      end

    channel = if side == :source, do: c.source_channel, else: c.channel
    sequence = if side == :source, do: 3, else: 4
    assert historical.id != c.start.id and historical.generation < c.start.generation
    before_authority = authority()
    {before_physical, before_events} = proof_inventory()
    before_accounting = accounting_inventory()
    stale = ingest(channel, historical, sequence, :running)
    assert stale.operation_id == historical.id and stale.generation == historical.generation
    assert stale.host_id == historical.command_snapshot["host_id"]
    assert DateTime.compare(stale.inserted_at, attempt.admitted_at) != :lt
    assert DateTime.compare(stale.inserted_at, attempt.deadline) != :gt
    assert authority() == before_authority
    assert accounting_inventory() == before_accounting
    assert proof_inventory() == {Enum.sort_by([stale | before_physical], & &1.id), before_events}
    retained = proof_inventory()
    pending_unrelated = unrelated_accounting(attempt.id, total.id)

    for _ <- 1..repeats do
      assert {:ok, 0} = WorkflowServiceLevels.reconcile()
      assert [pending] = Ledger.read!(WorkflowServiceLevelAttempt, id: attempt.id)
      assert pending.status == :pending and pending.success == nil and pending.completed_at == nil
      assert pending.admitted_at == attempt.admitted_at and pending.deadline == attempt.deadline
      assert [^total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)
      assert authority() == before_authority and proof_inventory() == retained
      assert unrelated_accounting(attempt.id, total.id) == pending_unrelated
      assert Map.delete(pending, :checked_at) == Map.delete(attempt, :checked_at)
    end

    current = ingest(c.channel, c.start, sequence + 1, :running)
    assert {:ok, %{"commands" => [wire]}} = exchange(:ready, c.channel, [])
    assert {:ok, command} = OverallsProtocol.RelocationReadiness.command(wire)
    assert command.id == c.start.id and command.generation == c.start.generation

    assert {:ok, _} =
             exchange(:ready, c.channel, [
               %{
                 id: command.id,
                 generation: command.generation,
                 descriptor: command.descriptor,
                 boot_id: Ash.UUID.generate()
               }
             ])

    assert [%{status: :ready}] = Ledger.read!(ReadinessRequest, id: c.start.id)

    assert [ready] =
             Ledger.read!(LifecycleEvent,
               resource_type: "ReadinessRequest",
               resource_id: c.start.id,
               measurement_outcome: :succeeded
             )

    completed =
      Enum.max_by([current.inserted_at, ready.inserted_at], &DateTime.to_unix(&1, :microsecond))

    duration = DateTime.diff(completed, attempt.admitted_at, :microsecond)
    before_delayed = authority()
    {delayed_physical, delayed_events} = proof_inventory()
    delayed_accounting = accounting_inventory()
    delayed = ingest(channel, historical, sequence + 2, :running)
    assert delayed.operation_id == historical.id and delayed.generation == historical.generation
    assert DateTime.compare(delayed.inserted_at, ready.inserted_at) == :gt
    assert DateTime.compare(delayed.inserted_at, attempt.deadline) != :gt
    assert authority() == before_delayed
    assert accounting_inventory() == delayed_accounting

    assert proof_inventory() ==
             {Enum.sort_by([delayed | delayed_physical], & &1.id), delayed_events}

    before_finish_authority = authority()
    before_finish_proofs = proof_inventory()
    before_unrelated = unrelated_accounting(attempt.id, total.id)
    assert {:ok, 1} = WorkflowServiceLevels.reconcile()
    assert authority() == before_finish_authority
    assert proof_inventory() == before_finish_proofs
    assert unrelated_accounting(attempt.id, total.id) == before_unrelated
    [terminal] = Ledger.read!(WorkflowServiceLevelAttempt, id: attempt.id)
    assert terminal.status == :finished and terminal.success
    assert terminal.admitted_at == attempt.admitted_at and terminal.deadline == attempt.deadline
    assert terminal.completed_at == completed and terminal.duration_us == duration
    [after_total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)

    assert after_total.requests == total.requests + 1 and
             after_total.successes == total.successes + 1

    assert after_total.failures == total.failures
    bucket = Enum.find_index(@duration_bounds, &(duration <= &1)) || length(@duration_bounds)
    assert after_total.bucket_counts == List.update_at(total.bucket_counts, bucket, &(&1 + 1))
    assert after_total.duration_sum_us == total.duration_sum_us + duration
    assert after_total.id == total.id and after_total.started_at == total.started_at
    terminal_authority = authority()
    {terminal_physical, terminal_events} = proof_inventory()
    terminal_accounting = accounting_inventory()
    after_terminal = ingest(channel, historical, sequence + 3, :running)
    assert after_terminal.operation_id == historical.id
    assert after_terminal.generation == historical.generation
    assert DateTime.compare(after_terminal.inserted_at, terminal.completed_at) == :gt
    assert authority() == terminal_authority
    assert accounting_inventory() == terminal_accounting

    assert proof_inventory() ==
             {Enum.sort_by([after_terminal | terminal_physical], & &1.id), terminal_events}

    after_authority = authority()
    after_proofs = proof_inventory()
    after_accounting = accounting_inventory()

    for _ <- 1..repeats do
      assert {:ok, 0} = WorkflowServiceLevels.reconcile()
      assert [^terminal] = Ledger.read!(WorkflowServiceLevelAttempt, id: attempt.id)
      assert accounting_inventory() == after_accounting
      assert authority() == after_authority and proof_inventory() == after_proofs
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification;accounting] retry-immutable-deadline-crossing
  # Missing retry proofs MUST remain pending before the fixed deadline, then
  # count one failure after the database clock crosses that same deadline.
  # Setup-only sandbox clock controls MUST NOT change admission/window between
  # scans. Timeout MUST preserve authority, proof and unrelated accounting rows.
  property "pending retry measurements fail once across their unchanged deadline",
    profile: :ci,
    test_cases: 2 do
    check all(
            presence <- member_of([:none, :physical]),
            repeats <- member_of([1, 2, 4]),
            test_cases: 2
          ) do
      for proofs <- [presence, :none, :physical] do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)

        try do
          crossing_history(proofs, repeats)
        after
          :ok = Ecto.Adapters.SQL.Sandbox.checkin(Marshall.Repo)
        end
      end
    end
  end

  @spec crossing_history(:none | :physical, pos_integer()) :: :ok
  defp crossing_history(presence, repeats) do
    c = prepare_retry()
    if presence == :physical, do: ingest(c.channel, c.start, 3, :running)
    # Retain the configured 600-second window; setup leaves five seconds to cross.
    admitted = DateTime.add(Ledger.now(), -595)
    deadline = DateTime.add(admitted, 600)

    assert %{num_rows: 1} =
             Marshall.Repo.query!(
               "UPDATE compute_workflow_service_level_attempts SET admitted_at=$1, deadline=$2 WHERE id=$3",
               [
                 DateTime.to_naive(admitted),
                 DateTime.to_naive(deadline),
                 Ecto.UUID.dump!(c.measurement.id)
               ],
               log: false
             )

    before_authority = authority()
    before_proofs = proof_inventory()
    [total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)
    unrelated = unrelated_accounting(c.measurement.id, total.id)

    for _ <- 1..repeats do
      assert DateTime.compare(Ledger.now(), deadline) == :lt
      assert {:ok, 0} = WorkflowServiceLevels.reconcile()
      assert [pending] = Ledger.read!(WorkflowServiceLevelAttempt, id: c.measurement.id)
      assert pending.status == :pending and pending.success == nil and pending.completed_at == nil
      assert pending.admitted_at == admitted and pending.deadline == deadline
      assert [^total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)
      assert authority() == before_authority and proof_inventory() == before_proofs
      assert unrelated_accounting(c.measurement.id, total.id) == unrelated
    end

    wait_for_deadline(deadline)
    assert {:ok, 1} = WorkflowServiceLevels.reconcile()
    [finished] = Ledger.read!(WorkflowServiceLevelAttempt, id: c.measurement.id)
    assert finished.status == :finished and finished.success == false
    assert finished.admitted_at == admitted and finished.deadline == deadline
    assert finished.completed_at == deadline and finished.duration_us == 600_000_000
    [after_total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)

    assert after_total.requests == total.requests + 1 and
             after_total.failures == total.failures + 1

    assert after_total.successes == total.successes
    assert after_total.bucket_counts == List.update_at(total.bucket_counts, 5, &(&1 + 1))
    assert after_total.duration_sum_us == total.duration_sum_us + 600_000_000
    assert after_total.id == total.id and after_total.started_at == total.started_at
    assert authority() == before_authority and proof_inventory() == before_proofs
    assert unrelated_accounting(c.measurement.id, total.id) == unrelated
    terminal_accounting = accounting_inventory()

    for _ <- 1..repeats do
      assert {:ok, 0} = WorkflowServiceLevels.reconcile()
      assert [^finished] = Ledger.read!(WorkflowServiceLevelAttempt, id: c.measurement.id)
      assert accounting_inventory() == terminal_accounting
      assert authority() == before_authority and proof_inventory() == before_proofs
    end

    :ok
  end

  @spec wait_for_deadline(DateTime.t()) :: :ok
  defp wait_for_deadline(deadline) do
    wait_ms = max(DateTime.diff(deadline, Ledger.now(), :millisecond), 0) + 25
    marker = make_ref()
    Process.send_after(self(), marker, wait_ms)
    assert_receive ^marker, wait_ms + 1000
    assert DateTime.compare(Ledger.now(), deadline) != :lt
    :ok
  end

  @spec unrelated_accounting(String.t(), String.t()) ::
          {[Compute.ServiceLevelAttempt.t()], [WorkflowServiceLevelAttempt.t()],
           [ServiceLevelTotal.t()]}
  defp unrelated_accounting(attempt_id, total_id) do
    {physical, workflows, totals} = accounting_inventory()

    {physical, Enum.reject(workflows, &(&1.id == attempt_id)),
     Enum.reject(totals, &(&1.id == total_id))}
  end

  @spec accounting_inventory() ::
          {[Compute.ServiceLevelAttempt.t()], [WorkflowServiceLevelAttempt.t()],
           [ServiceLevelTotal.t()]}
  defp accounting_inventory do
    {Enum.sort_by(Ledger.read!(Compute.ServiceLevelAttempt), & &1.id),
     Enum.sort_by(Ledger.read!(WorkflowServiceLevelAttempt), & &1.id),
     Enum.sort_by(Ledger.read!(ServiceLevelTotal), & &1.id)}
  end

  @type channel :: %{token: String.t(), session_id: String.t(), epoch: pos_integer()}
  @type fixture :: %{
          host: Host.t(),
          pool: Compute.StoragePool.t(),
          epoch: pos_integer(),
          report: OverallsProtocol.report()
        }
  @type kind :: :keys | :source | :receive | :import | :revoke | :quiesce | :ready
  @type result ::
          OverallsProtocol.RelocationKeys.result()
          | OverallsProtocol.RelocationSource.result()
          | OverallsProtocol.RelocationReceive.result()
          | OverallsProtocol.RelocationRevocation.result()
          | OverallsProtocol.RelocationReadiness.result()
  @type prepared :: %{
          owner: Marshall.Accounts.User.t(),
          vm: VirtualMachine.t(),
          relocation: Relocation.t(),
          retry: RelocationRetry.t(),
          start: Operation.t(),
          channel: channel(),
          source_channel: channel(),
          old_ready: OverallsProtocol.RelocationReadiness.result(),
          measurement: WorkflowServiceLevelAttempt.t()
        }

  @spec window_history(
          -1 | 0 | 599 | 600 | 601,
          -1 | 0 | 599 | 600 | 601,
          :before | :after,
          :none | :physical | :both,
          pos_integer()
        ) :: :ok
  defp window_history(p, r, phase, presence, repeats) do
    c = prepare_retry()

    early = %{
      c.old_ready
      | id: c.start.id,
        generation: c.start.generation,
        boot_id: Ash.UUID.generate()
    }

    before_early = authority()
    assert {:error, :invalid_outcome} = exchange(:ready, c.channel, [early])
    assert authority() == before_early
    assert {:ok, 0} = WorkflowServiceLevels.reconcile()
    assert [%{status: :pending}] = Ledger.read!(WorkflowServiceLevelAttempt, id: c.measurement.id)

    physical =
      if presence != :none do
        proof = ingest(c.channel, c.start, 3, :running)
        assert {:ok, %{"commands" => [wire]}} = exchange(:ready, c.channel, [])
        assert {:ok, command} = OverallsProtocol.RelocationReadiness.command(wire)
        assert command.id == c.start.id and command.generation == c.start.generation

        if presence == :both do
          receipt = %{
            id: command.id,
            generation: command.generation,
            descriptor: command.descriptor,
            boot_id: Ash.UUID.generate()
          }

          assert {:ok, _} = exchange(:ready, c.channel, [receipt])
        end

        proof
      end

    anchor = DateTime.add(Ledger.now(), if(phase == :before, do: -300, else: -601))
    deadline = DateTime.add(anchor, 600)

    assert %{num_rows: 1} =
             Marshall.Repo.query!(
               "UPDATE compute_workflow_service_level_attempts SET admitted_at=$1, deadline=$2 WHERE id=$3",
               [
                 DateTime.to_naive(anchor),
                 DateTime.to_naive(deadline),
                 Ecto.UUID.dump!(c.measurement.id)
               ],
               log: false
             )

    if physical, do: received_time(:physical, physical.id, DateTime.add(anchor, p))

    if presence == :both do
      assert [event] =
               Ledger.read!(LifecycleEvent,
                 resource_type: "ReadinessRequest",
                 resource_id: c.start.id,
                 measurement_outcome: :succeeded
               )

      received_time(:ready, event.id, DateTime.add(anchor, r))
    end

    allocations = authority()
    evidence = proof_inventory()
    [before] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)
    now = Ledger.now()

    valid =
      presence == :both and p in 0..600 and r in 0..600 and
        DateTime.compare(DateTime.add(anchor, max(p, r)), now) != :gt

    expected =
      cond do
        valid -> :succeeded
        DateTime.compare(now, deadline) != :lt -> :failed
        true -> :pending
      end

    first =
      Enum.reduce(1..repeats, nil, fn scan, prior ->
        count = if scan == 1 and expected != :pending, do: 1, else: 0
        assert {:ok, ^count} = WorkflowServiceLevels.reconcile()
        assert [row] = Ledger.read!(WorkflowServiceLevelAttempt, id: c.measurement.id)
        assert row.admitted_at == anchor and row.deadline == deadline
        assert authority() == allocations
        assert proof_inventory() == evidence
        [total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)

        if expected == :pending do
          assert row.status == :pending and row.success == nil and row.completed_at == nil
          assert total == before
        else
          success = expected == :succeeded
          seconds = if success, do: max(p, r), else: 600
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

          if prior do
            {prior_row, prior_total} = prior
            assert row == prior_row
            assert total == prior_total
          end
        end

        {row, total}
      end)

    {first_row, first_total} = first
    assert first_row.deadline == deadline

    if expected == :failed and presence != :both do
      if presence == :none, do: ingest(c.channel, c.start, 3, :running)
      assert {:ok, %{"commands" => [late_wire]}} = exchange(:ready, c.channel, [])
      assert {:ok, late_command} = OverallsProtocol.RelocationReadiness.command(late_wire)
      assert late_command.id == c.start.id and late_command.generation == c.start.generation

      assert {:ok, _} =
               exchange(:ready, c.channel, [
                 %{
                   id: late_command.id,
                   generation: late_command.generation,
                   descriptor: late_command.descriptor,
                   boot_id: Ash.UUID.generate()
                 }
               ])

      assert [%{status: :ready, boot_id: late_boot}] =
               Ledger.read!(ReadinessRequest, id: c.start.id)

      assert is_binary(late_boot)

      assert [%{generation: late_generation, workflow_id: late_workflow}] =
               Ledger.read!(LifecycleEvent,
                 resource_type: "ReadinessRequest",
                 resource_id: c.start.id,
                 measurement_outcome: :succeeded
               )

      assert late_generation == c.start.generation
      assert late_workflow == c.relocation.id

      late_authority = authority()
      late_proofs = proof_inventory()

      for _ <- 1..repeats do
        assert {:ok, 0} = WorkflowServiceLevels.reconcile()
        assert [^first_row] = Ledger.read!(WorkflowServiceLevelAttempt, id: c.measurement.id)
        assert [^first_total] = Ledger.read!(ServiceLevelTotal, service: :porsche_retry)
        assert authority() == late_authority
        assert proof_inventory() == late_proofs
      end
    end

    :ok
  end

  @spec prepare_retry() :: prepared()
  defp prepare_retry do
    source = roomy_host()
    owner = user()
    assert {:ok, vm} = Compute.provision(request(), actor: owner)
    source_channel = connect(source.host)
    [provision] = Ledger.read!(Operation, vm_id: vm.id)
    offer_execution(source_channel, provision)
    ingest(source_channel, provision, 1, :running)
    destination = roomy_host()
    target = connect(destination.host)
    refresh(source, source_channel, 3)
    refresh(destination, target, 3)

    assert {:ok, relocation} =
             Compute.relocate(%{vm_id: vm.id, idempotency_key: Ash.UUID.generate()}, actor: owner)

    assert {:ok, %{"commands" => [key_wire]}} = exchange(:keys, target, [])
    assert {:ok, key} = OverallsProtocol.RelocationKeys.command(key_wire)

    assert {:ok, _} =
             exchange(:keys, target, [
               %{
                 id: key.id,
                 placement_id: key.placement_id,
                 execution_epoch: key.execution_epoch,
                 public_key: transfer_endpoint()["host_key"]
               }
             ])

    # ADR-0155: no running-source copy; fresh connectivity proof gates the stop.
    assert {:ok, :waiting} = RelocationCoordinator.advance(relocation.id)
    assert {:ok, %{"commands" => []}} = exchange(:source, source_channel, [])
    [keyed] = Ledger.read!(Relocation, id: relocation.id)
    [running] = Ledger.read!(Marshall.Compute.VirtualMachine, id: vm.id)
    Marshall.RelocationProbeFixture.applied!(keyed, running)
    refresh(source, source_channel, 4)
    refresh(destination, target, 4)
    assert {:ok, :stopping} = RelocationCoordinator.advance(relocation.id)
    [relocation] = Ledger.read!(Relocation, id: relocation.id)
    [stop] = Ledger.read!(Operation, id: relocation.source_stop_operation_id)
    offer_execution(source_channel, stop)
    ingest(source_channel, stop, 2, :stopped)
    assert {:ok, %{"commands" => [full_wire]}} = exchange(:source, source_channel, [])
    assert {:ok, full} = OverallsProtocol.RelocationSource.command(full_wire)
    assert full.to_guid == nil
    final = captured(full, "201")
    assert {:ok, _} = exchange(:source, source_channel, [final])
    assert {:ok, %{"commands" => [_]}} = exchange(:receive, target, [])
    imported = Map.put(final, :dataset_guid, "300")
    assert {:ok, _} = exchange(:receive, target, [imported])
    assert {:ok, %{"commands" => [_]}} = exchange(:import, target, [])
    assert {:ok, _} = exchange(:import, target, [imported])
    assert {:ok, :committed} = RelocationCoordinator.advance(relocation.id)
    [committed] = Ledger.read!(Relocation, id: relocation.id)

    for {side, channel, placement, epoch} <- [
          {:revoke, source_channel, committed.source_placement_id, committed.source_epoch},
          {:quiesce, target, committed.destination_placement_id, committed.destination_epoch}
        ] do
      assert {:ok, %{"commands" => [_]}} = exchange(side, channel, [])

      assert {:ok, _} =
               exchange(side, channel, [
                 %{id: relocation.id, placement_id: placement, execution_epoch: epoch}
               ])
    end

    assert {:ok, :committed} = RelocationCoordinator.advance(relocation.id)
    [activation] = Ledger.read!(Operation, id: committed.activation_operation_id)
    offer_execution(target, activation)
    ingest(target, activation, 1, :running)
    assert {:ok, %{"commands" => [wire]}} = exchange(:ready, target, [])
    assert {:ok, original} = OverallsProtocol.RelocationReadiness.command(wire)

    old_ready = %{
      id: original.id,
      descriptor: original.descriptor,
      generation: original.generation,
      boot_id: Ash.UUID.generate()
    }

    assert %{num_rows: 1} =
             Marshall.Repo.query!(
               "UPDATE compute_readiness_requests SET deadline_at=$1 WHERE id=$2",
               [DateTime.to_naive(DateTime.add(Ledger.now(), -1)), Ecto.UUID.dump!(original.id)],
               log: false
             )

    assert {:ok, _} = exchange(:ready, target, [old_ready])
    assert [%{status: :failed}] = Ledger.read!(ReadinessRequest, id: original.id)
    started = Ledger.now()

    assert {:ok, retry} =
             Compute.retry_relocation(
               %{relocation_id: relocation.id, idempotency_key: Ash.UUID.generate()},
               actor: owner
             )

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
        measurement_started_at: started
      })

    [measurement] = Ledger.read!(WorkflowServiceLevelAttempt, request_id: receipt.id)
    [retry_stop] = Ledger.read!(Operation, id: retry.stop_operation_id)
    offer_execution(target, retry_stop)
    ingest(target, retry_stop, 2, :stopped)
    refresh(source, source_channel, 5)
    refresh(destination, target, 5)
    assert {:ok, :reactivating} = RelocationCoordinator.advance(relocation.id)
    [retry] = Ledger.read!(RelocationRetry, id: retry.id)
    [start] = Ledger.read!(Operation, id: retry.start_operation_id)
    offer_execution(target, start)

    %{
      owner: owner,
      vm: vm,
      relocation: committed,
      retry: retry,
      start: start,
      channel: target,
      source_channel: source_channel,
      old_ready: old_ready,
      measurement: measurement
    }
  end

  @spec roomy_host() :: fixture()
  defp roomy_host do
    fixture = host_fixture()

    report = %{
      fixture.report
      | pools:
          Enum.map(fixture.report.pools, fn pool ->
            %{
              pool
              | total_bytes: 34_359_738_368,
                free_bytes: 34_359_738_368,
                storage: storage_observation(fixture.pool, 34_359_738_368, 34_359_738_368)
            }
          end)
    }

    assert {:ok, :ok} =
             HostReports.ingest(fixture.host.id, fixture.epoch, %{report | sequence: 2})

    %{fixture | report: report}
  end

  @spec connect(Host.t()) :: channel()
  defp connect(host) do
    assert {:ok, credential} = Credentials.rotate(host.id, 3600)
    session = Ash.UUID.generate()

    assert {:ok, reply} =
             Compute.ProvisionerControl.open_execution(
               credential.token,
               %{session_id: session, machine_id: host.machine_id}
             )

    %{token: credential.token, session_id: session, epoch: reply["epoch"]}
  end

  @spec refresh(fixture(), channel(), pos_integer()) :: :ok
  defp refresh(fixture, channel, sequence) do
    assert {:ok, :ok} =
             HostReports.ingest(fixture.host.id, channel.epoch, %{
               fixture.report
               | sequence: sequence,
                 sampled_at: Ledger.now()
             })

    :ok
  end

  @spec exchange(kind(), channel(), [result()]) :: {:ok, map()} | {:error, term()}
  defp exchange(kind, channel, results) do
    {component, decoder} =
      case kind do
        :keys ->
          {Compute.RelocationKeys, OverallsProtocol.RelocationKeys}

        :source ->
          {Compute.RelocationSources, OverallsProtocol.RelocationSource}

        :receive ->
          {Compute.RelocationReceives, OverallsProtocol.RelocationReceive}

        :import ->
          {Compute.RelocationImports, OverallsProtocol.RelocationImport}

        :revoke ->
          {Compute.RelocationRevocations, OverallsProtocol.RelocationRevocation}

        :quiesce ->
          {Compute.RelocationDestinationRevocations,
           OverallsProtocol.RelocationDestinationRevocation}

        :ready ->
          {Compute.RelocationReadiness, OverallsProtocol.RelocationReadiness}
      end

    wire =
      Jason.decode!(
        Jason.encode!(%{
          "version" => 4,
          "session_id" => channel.session_id,
          "epoch" => channel.epoch,
          "results" =>
            Enum.map(results, fn result ->
              case kind do
                :source ->
                  OverallsProtocol.RelocationSource.encode_result(result)

                kind when kind in [:receive, :import] ->
                  OverallsProtocol.RelocationReceive.encode_result(result)

                :ready ->
                  OverallsProtocol.RelocationReadiness.encode_result(result)

                _ ->
                  result
              end
            end)
        })
      )

    assert {:ok, parsed} = decoder.exchange(wire)
    component.exchange(channel.token, parsed)
  end

  @spec captured(OverallsProtocol.RelocationSource.command(), String.t()) ::
          OverallsProtocol.RelocationSource.result()
  defp captured(command, guid) do
    %{
      id: command.id,
      descriptor: Map.put(command.intent, :stream, %{source_dataset_guid: "100", to_guid: guid})
    }
  end

  @spec offer_execution(channel(), Operation.t()) :: :ok
  defp offer_execution(channel, operation) do
    assert {:ok, %{"commands" => commands}} =
             Compute.ProvisionerControl.exchange_execution(
               channel.token,
               %{
                 session_id: channel.session_id,
                 epoch: channel.epoch,
                 report: nil,
                 acknowledgements: [],
                 outcomes: []
               }
             )

    assert Enum.any?(commands, &(&1["id"] == operation.id))
    :ok
  end

  @spec ingest(channel(), Operation.t(), pos_integer(), :running | :stopped) ::
          PhysicalOutcome.t()
  defp ingest(channel, operation, sequence, state) do
    event = %{
      id: Ash.UUID.generate(),
      operation_id: operation.id,
      vm_id: operation.vm_id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      generation: operation.generation,
      sequence: sequence,
      state: state,
      compute_empty: state == :stopped,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    assert {:ok, proof} =
             OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    assert {:ok, _} =
             Compute.ProvisionerControl.exchange_execution(
               channel.token,
               %{
                 session_id: channel.session_id,
                 epoch: channel.epoch,
                 report: nil,
                 acknowledgements: [],
                 outcomes: [proof]
               }
             )

    hd(Ledger.read!(PhysicalOutcome, id: event.id))
  end

  @spec received_time(:physical | :ready, String.t(), DateTime.t()) :: :ok
  defp received_time(kind, id, time) do
    table =
      if kind == :physical, do: "compute_physical_outcomes", else: "compute_lifecycle_events"

    assert %{num_rows: 1} =
             Marshall.Repo.query!(
               "UPDATE #{table} SET inserted_at=$1 WHERE id=$2",
               [DateTime.to_naive(time), Ecto.UUID.dump!(id)],
               log: false
             )

    :ok
  end

  @type authority ::
          {[VirtualMachine.t()], [Compute.WorkloadPlacement.t()], [Compute.Reservation.t()],
           [Compute.NetworkAddress.t()], [Operation.t()], [Compute.TransferSlot.t()],
           [Relocation.t()], [RelocationRetry.t()], [ReadinessRequest.t()],
           [Marshall.SSH.Request.t()]}
  @spec authority() :: authority()
  defp authority do
    {Enum.sort_by(Ledger.read!(VirtualMachine), & &1.id),
     Enum.sort_by(Ledger.read!(Compute.WorkloadPlacement), & &1.id),
     Enum.sort_by(Ledger.read!(Compute.Reservation), & &1.id),
     Enum.sort_by(Ledger.read!(Compute.NetworkAddress), & &1.id),
     Enum.sort_by(Ledger.read!(Operation), & &1.id),
     Enum.sort_by(Ledger.read!(Compute.TransferSlot), & &1.id),
     Enum.sort_by(Ledger.read!(Relocation), & &1.id),
     Enum.sort_by(Ledger.read!(RelocationRetry), & &1.id),
     Enum.sort_by(Ledger.read!(ReadinessRequest), & &1.id),
     Enum.sort_by(Ledger.read!(Marshall.SSH.Request), & &1.id)}
  end

  @spec proof_inventory() :: {[PhysicalOutcome.t()], [LifecycleEvent.t()]}
  defp proof_inventory do
    {Enum.sort_by(Ledger.read!(PhysicalOutcome), & &1.id),
     Enum.sort_by(Ledger.read!(LifecycleEvent), & &1.id)}
  end
end
