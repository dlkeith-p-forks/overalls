defmodule Marshall.Compute.LifecycleTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Accounts.AdminEvent
  alias Marshall.Compute

  alias Marshall.Compute.{
    Host,
    HostReports,
    Image,
    Ledger,
    NetworkAddress,
    Operation,
    Outcomes,
    PhysicalOutcome,
    Reservation,
    StoragePool,
    VirtualMachine
  }

  setup do
    fixture = host_fixture()
    actor = user()
    params = request()
    {:ok, vm} = Compute.provision(params, actor: actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    Map.merge(fixture, %{user: actor, vm: vm, operation: operation, params: params})
  end

  test "lifecycle diagnostics follow the catalog after commit and refusal", context do
    %{vm: vm, operation: original} = context
    assert {:ok, _} = ingest(vm.host_id, outcome(original, 1, :running))

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    {{:ok, stop}, requested} =
      ExUnit.CaptureLog.with_log([metadata: [:event, :vm_id, :operation_id]], fn ->
        lifecycle(context, :stop)
      end)

    assert requested =~ "VM lifecycle requested"
    assert requested =~ "event=vm.lifecycle_requested"
    assert requested =~ "vm_id=" <> vm.id
    assert requested =~ "operation_id=" <> stop.id

    {:ok, _} = ingest(vm.host_id, outcome(stop, 2, :stopped))
    Ledger.update!(vm, :request_delete, %{})

    refused =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :vm_id, :reason]], fn ->
        assert {:error, _} = lifecycle(context, :start)
      end)

    assert refused =~ "VM lifecycle request refused"
    assert refused =~ "event=vm.lifecycle_refused"
    assert refused =~ "vm_id=" <> vm.id
    assert refused =~ "reason=vm_deleted"
  end

  test "stop releases compute only on its physical result; start retains the disk and address",
       context do
    %{vm: vm, operation: original} = context
    assert {:ok, _} = ingest(vm.host_id, outcome(original, 1, :running))
    assert {:ok, stop} = lifecycle(context, :stop)
    assert stop.generation == 2
    assert %{compute_held: true, disk_held: true} = reservation(vm)
    [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)

    assert {:ok, _} = ingest(vm.host_id, outcome(stop, 2, :unknown))
    assert %{compute_held: true, disk_held: true} = reservation(vm)
    assert {:ok, _} = ingest(vm.host_id, outcome(stop, 3, :stopped))
    assert %{compute_held: false, disk_held: true} = reservation(vm)
    assert {:ok, start} = lifecycle(context, :start)
    assert start.generation == 3
    assert reservation(vm).compute_held
    assert reservation(vm).memory_bytes == vm.memory_bytes + 67_108_864
    assert [^address] = Ledger.read!(NetworkAddress, vm_id: vm.id)
    assert {:ok, _} = ingest(vm.host_id, outcome(start, 4, :running))
    assert current(vm).observed_state == :running
    assert current(vm).host_id == vm.host_id
  end

  test "administrator lifecycle requests are audited once and replay is idempotent", context do
    admin =
      Ledger.update!(context.user, :assign_administrator, %{administrator: true})
      |> Marshall.PasskeyFixture.verified_session()

    key = Ash.UUID.generate()

    assert {:ok, operation} =
             Compute.lifecycle(%{vm_id: context.vm.id, kind: :stop, idempotency_key: key},
               actor: admin
             )

    assert {:ok, replay} =
             Compute.lifecycle(%{vm_id: context.vm.id, kind: :stop, idempotency_key: key},
               actor: admin
             )

    assert replay.id == operation.id

    assert [%{kind: :vm_lifecycle, actor_id: actor_id, target_id: target_id}] =
             Ledger.read!(AdminEvent, target_id: context.vm.id)

    assert actor_id == admin.id
    assert target_id == context.vm.id
  end

  test "restart exhaustion rejects immediately without a new generation or operation", context do
    %{vm: vm, user: actor} = context
    {:ok, stop} = lifecycle(context, :stop)
    assert {:ok, _} = ingest(vm.host_id, outcome(stop, 1, :stopped))
    assert {:ok, _} = Compute.provision(request(), actor: actor)
    assert {:ok, _} = Compute.provision(request(), actor: actor)
    assert {:error, error} = lifecycle(context, :start)
    assert Exception.message(error) =~ "insufficient_capacity"
    assert current(vm).generation == stop.generation
    refute reservation(vm).compute_held
    assert length(Ledger.read!(Operation, vm_id: vm.id)) == 2
  end

  test "delete retains uncertain allocations, then archives and makes the address reusable",
       context do
    %{vm: vm, user: actor, params: params} = context
    [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)
    key = Ash.UUID.generate()
    {:ok, delete} = lifecycle(context, :delete, key)
    assert {:ok, _} = ingest(vm.host_id, outcome(delete, 1, :unknown))
    assert %{compute_held: true, disk_held: true} = reservation(vm)
    assert [^address] = Ledger.read!(NetworkAddress, vm_id: vm.id)
    assert {:ok, _} = ingest(vm.host_id, outcome(delete, 2, :deleted))
    assert %{compute_held: false, disk_held: false} = reservation(vm)
    assert [] = Ledger.read!(VirtualMachine, id: vm.id)
    assert [] = Ledger.read!(NetworkAddress, vm_id: vm.id)
    assert %DateTime{} = current(vm).archived_at
    assert {:ok, replay} = lifecycle(context, :delete, key)
    assert replay.id == delete.id
    assert {:error, error} = lifecycle(context, :start)
    assert Exception.message(error) =~ "vm_deleted"
    assert {:ok, replay_vm} = Compute.provision(params, actor: actor)
    assert replay_vm.id == vm.id
    assert replay_vm.archived_at != nil
    assert {:ok, successor} = Compute.provision(request(), actor: actor)
    [new_address] = Ledger.read!(NetworkAddress, vm_id: successor.id)
    assert new_address.slot == address.slot
  end

  test "superseded and reordered observations are audited without undoing newer state", context do
    %{vm: vm, operation: provision} = context
    {:ok, stop} = lifecycle(context, :stop)
    {:ok, start} = lifecycle(context, :start)
    assert {:ok, _} = ingest(vm.host_id, outcome(start, 10, :running))
    assert {:ok, _} = ingest(vm.host_id, outcome(stop, 20, :stopped))
    assert {:ok, _} = ingest(vm.host_id, outcome(provision, 30, :failed, :crashed))
    assert {:ok, _} = ingest(vm.host_id, outcome(start, 9, :failed, :crashed))
    assert current(vm).observed_state == :running
    assert current(vm).generation == start.generation
    assert current(vm).outcome_sequence == 10
    assert reservation(vm).compute_held
    assert length(Ledger.read!(PhysicalOutcome, vm_id: vm.id)) == 4
    assert length(Ledger.read!(Operation, vm_id: vm.id)) == 3
    assert [%{status: :cancelled}] = Ledger.read!(Operation, id: provision.id)
    assert [%{status: :cancelled}] = Ledger.read!(Operation, id: stop.id)
  end

  test "replays are idempotent; changed IDs, sequences and host bindings roll back", context do
    %{vm: vm, operation: operation} = context
    event = outcome(operation, 1, :running)
    assert {:ok, [id]} = ingest(vm.host_id, event)
    assert id == event.id
    assert {:ok, [^id]} = ingest(vm.host_id, event)
    assert {:error, :outcome_conflict} = ingest(vm.host_id, %{event | sequence: 2})
    assert {:error, :outcome_conflict} = ingest(vm.host_id, %{event | id: Ash.UUID.generate()})
    other = host_fixture()
    assert {:error, :outcome_conflict} = ingest(other.host.id, event)
    assert {:error, :invalid_outcome} = ingest(other.host.id, %{event | id: Ash.UUID.generate()})

    assert {:error, :invalid_outcome} =
             ingest(vm.host_id, %{event | id: Ash.UUID.generate(), generation: 2})

    assert {:error, :invalid_outcome} = ingest(vm.host_id, outcome(operation, 2, :deleted))
    assert length(Ledger.read!(PhysicalOutcome, vm_id: vm.id)) == 1
  end

  test "three crash restarts are durable and the fourth crash releases compute only", context do
    %{vm: vm, operation: initial} = context

    last =
      Enum.reduce(1..3, initial, fn sequence, operation ->
        assert {:ok, _} = ingest(vm.host_id, outcome(operation, sequence, :failed, :crashed))
        vm = current(vm)
        assert length(vm.crash_restart_times) == sequence
        assert reservation(vm).compute_held
        [next] = Ledger.read!(Operation, vm_id: vm.id, generation: vm.generation)
        assert next.kind == :start
        assert next.initiator == :recovery
        assert next.requested_by_id == nil
        assert next.generation == operation.generation + 1
        next
      end)

    assert {:ok, _} = ingest(vm.host_id, outcome(last, 4, :failed, :crashed))
    assert current(vm).observed_state == :failed
    assert current(vm).generation == last.generation
    assert %{compute_held: false, disk_held: true} = reservation(vm)
    assert length(Ledger.read!(Operation, vm_id: vm.id)) == 4
    # A fenced failed generation cannot report a later running VM against freed RAM.
    assert {:error, :outcome_conflict} = ingest(vm.host_id, outcome(last, 5, :running))
  end

  test "expired crash attempts permit recovery and explicit stop cancels it", context do
    %{vm: vm, operation: initial} = context

    Ledger.intent!(vm, %{
      crash_restart_times: List.duplicate(DateTime.add(Ledger.now(), -601), 3)
    })

    assert {:ok, _} = ingest(vm.host_id, outcome(initial, 1, :failed, :crashed))
    assert length(current(vm).crash_restart_times) == 1
    [recovery] = Ledger.read!(Operation, vm_id: vm.id, generation: 2)
    {:ok, stop} = lifecycle(context, :stop)
    assert current(vm).crash_restart_times == []
    assert {:ok, _} = ingest(vm.host_id, outcome(recovery, 2, :failed, :crashed))
    assert current(vm).generation == stop.generation
    assert current(vm).desired_state == :stopped
    assert reservation(vm).compute_held
    assert {:ok, _} = ingest(vm.host_id, outcome(stop, 3, :stopped))
    refute reservation(vm).compute_held
  end

  # @cc [owner:ghuntley,label:verification;recovery] crash-recovery-awaits-fresh-telemetry
  # A crash while capacity telemetry is stale MUST keep the compute hold and
  # enqueue no restart; the next accepted fresh report MUST start recovery.
  test "a crash during a late report waits for fresh telemetry, then recovers", context do
    %{vm: vm, operation: initial} = context
    old = DateTime.add(DateTime.utc_now(), -10, :second)
    [host] = Ledger.read!(Host, id: vm.host_id)
    Ledger.update!(host, :report, %{reported_at: old})

    for pool <- Ledger.read!(Marshall.Compute.StoragePool, host_id: vm.host_id),
        do: Ledger.update!(pool, :report, %{reported_at: old})

    assert {:ok, _} = ingest(vm.host_id, outcome(initial, 1, :failed, :crashed))
    assert current(vm).observed_state == :failed
    assert reservation(vm).compute_held
    assert [_only_initial] = Ledger.read!(Operation, vm_id: vm.id)

    report = %{
      context.report
      | sequence: host.report_sequence + 1,
        sampled_at: DateTime.utc_now()
    }

    assert {:ok, :ok} =
             Marshall.Compute.HostReports.ingest(context.host.id, context.epoch, report)

    vm = current(vm)
    assert length(vm.crash_restart_times) == 1
    [recovery] = Ledger.read!(Operation, vm_id: vm.id, generation: vm.generation)
    assert recovery.kind == :start and recovery.initiator == :recovery
  end

  # @cc [owner:ghuntley,label:verification;recovery] sourced-crash-retains-physical-proof
  # An obsolete image MUST prevent a sourced recovery start without rolling back
  # the accepted crash outcome or its completed operation. Confirmed stopped
  # compute MUST be released while the disk and network address remain retained.
  test "a sourced crash on an obsolete image commits proof and releases compute", context do
    {:ok, source} =
      OverallsProtocol.WorkspaceSource.parse_url("https://github.com/overalls/fixture")

    assert {:ok, vm} =
             Compute.provision(request(%{profile: :oss, workspace_source: source}),
               actor: context.user
             )

    [initial] = Ledger.read!(Operation, vm_id: vm.id)
    [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)
    [image] = Ledger.read!(Image, id: vm.image_id)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE compute_images SET manifest = $1 WHERE id = $2",
      [Map.put(image.manifest, "version", 3), image.id]
    )

    crashed = outcome(initial, 1, :failed, :crashed)
    assert {:ok, [accepted]} = ingest(vm.host_id, crashed)
    assert accepted == crashed.id
    assert {:ok, [^accepted]} = ingest(vm.host_id, crashed)
    assert [%{id: ^accepted}] = Ledger.read!(PhysicalOutcome, vm_id: vm.id)

    assert [%{status: :completed, completion_outcome_id: ^accepted}] =
             Ledger.read!(Operation, vm_id: vm.id)

    assert current(vm).generation == initial.generation
    assert current(vm).observed_state == :failed
    assert current(vm).failure_reason == :crashed
    assert current(vm).crash_restart_times == []
    assert %{compute_held: false, disk_held: true} = reservation(vm)
    assert [^address] = Ledger.read!(NetworkAddress, vm_id: vm.id)
    assert {:error, :outcome_conflict} = ingest(vm.host_id, outcome(initial, 2, :running))
  end

  # @cc [owner:ghuntley,label:verification;recovery] sourced-recovery-retains-fresh-report
  # When a sourced crash awaits fresh telemetry and its image becomes corrupt,
  # the next valid host report MUST commit its observations and release compute
  # without enqueueing recovery or discarding the previously accepted crash.
  test "fresh telemetry commits after a pending sourced recovery loses its image", context do
    {:ok, source} =
      OverallsProtocol.WorkspaceSource.parse_url("https://github.com/overalls/fixture")

    assert {:ok, vm} =
             Compute.provision(request(%{profile: :oss, workspace_source: source}),
               actor: context.user
             )

    [initial] = Ledger.read!(Operation, vm_id: vm.id)
    [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)
    [host] = Ledger.read!(Host, id: vm.host_id)
    old = DateTime.add(Ledger.now(), -10, :second)
    Ledger.update!(host, :report, %{reported_at: old})

    for pool <- Ledger.read!(StoragePool, host_id: vm.host_id),
        do: Ledger.update!(pool, :report, %{reported_at: old})

    crashed = outcome(initial, 1, :failed, :crashed)
    assert {:ok, [accepted]} = ingest(vm.host_id, crashed)
    assert accepted == crashed.id
    assert %{compute_held: true, disk_held: true} = reservation(vm)
    assert [%{status: :completed}] = Ledger.read!(Operation, vm_id: vm.id)

    [image] = Ledger.read!(Image, id: vm.image_id)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE compute_images SET manifest = $1 WHERE id = $2",
      [Map.put(image.manifest, "boot_args", "console=ttyS0 changed"), image.id]
    )

    report = %{
      context.report
      | sequence: host.report_sequence + 1,
        sampled_at: Ledger.now()
    }

    assert {:ok, :ok} = HostReports.ingest(vm.host_id, context.epoch, report)
    [fresh_host] = Ledger.read!(Host, id: vm.host_id)
    assert fresh_host.report_sequence == report.sequence
    assert DateTime.compare(fresh_host.reported_at, old) == :gt

    for pool <- Ledger.read!(StoragePool, host_id: vm.host_id),
        do: assert(DateTime.compare(pool.reported_at, old) == :gt)

    assert [%{id: ^accepted}] = Ledger.read!(PhysicalOutcome, vm_id: vm.id)

    assert [%{status: :completed, completion_outcome_id: ^accepted}] =
             Ledger.read!(Operation, vm_id: vm.id)

    assert current(vm).generation == initial.generation
    assert current(vm).observed_state == :failed
    assert current(vm).failure_reason == :crashed
    assert current(vm).crash_restart_times == []
    assert %{compute_held: false, disk_held: true} = reservation(vm)
    assert [^address] = Ledger.read!(NetworkAddress, vm_id: vm.id)
  end

  test "initial execution failure releases compute without an automatic retry", context do
    %{vm: vm, operation: operation} = context
    assert {:ok, _} = ingest(vm.host_id, outcome(operation, 1, :failed, :execution_failed))
    assert current(vm).generation == 1
    assert current(vm).observed_state == :failed
    assert %{compute_held: false, disk_held: true} = reservation(vm)
    assert length(Ledger.read!(Operation, vm_id: vm.id)) == 1
  end

  test "a backward database clock cannot discard recorded crash attempts", context do
    %{vm: vm, operation: operation} = context
    future = DateTime.add(Ledger.now(), 60)
    Ledger.intent!(vm, %{crash_restart_times: [future, future, future]})
    assert {:ok, _} = ingest(vm.host_id, outcome(operation, 1, :failed, :crashed))
    assert current(vm).generation == 1
    refute reservation(vm).compute_held
  end

  test "Cedar rejects another user and lifecycle keys cannot change meaning", context do
    assert {:error, _} = lifecycle(%{context | user: user()}, :stop)

    assert {:error, _} =
             Compute.lifecycle(%{vm_id: context.vm.id, kind: :stop, idempotency_key: "anonymous"})

    assert current(context.vm).generation == 1
    key = Ash.UUID.generate()
    assert {:ok, operation} = lifecycle(context, :stop, key)
    assert {:ok, same} = lifecycle(context, :stop, key)
    assert same.id == operation.id
    assert {:error, error} = lifecycle(context, :delete, key)
    assert Exception.message(error) =~ "idempotency_conflict"
    assert current(context.vm).generation == operation.generation
  end

  test "a disconnected host retains all capacity; stop/delete intent remains available",
       context do
    Ledger.update!(context.host, :report, %{reported_at: DateTime.add(Ledger.now(), -10)})
    assert {:error, error} = lifecycle(context, :start)
    assert Exception.message(error) =~ "host_unavailable"
    assert {:ok, _} = lifecycle(context, :stop)
    assert {:ok, _} = lifecycle(context, :delete)
    assert %{compute_held: true, disk_held: true} = reservation(context.vm)
  end

  defp lifecycle(context, kind, key \\ Ash.UUID.generate()) do
    Compute.lifecycle(%{vm_id: context.vm.id, kind: kind, idempotency_key: key},
      actor: context.user
    )
  end

  defp current(vm), do: Ledger.history!(VirtualMachine, id: vm.id) |> hd()
  defp reservation(vm), do: Ledger.read!(Reservation, vm_id: vm.id) |> hd()

  defp ingest(host, event) do
    {:ok, event} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    Ledger.transaction(fn ->
      Ledger.lock!(Host, host)
      Outcomes.ingest_locked!(host, [event])
    end)
  end

  defp outcome(operation, sequence, state, reason \\ :none) do
    %{
      id: Ash.UUID.generate(),
      vm_id: operation.vm_id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: sequence,
      state: state,
      compute_empty: state in [:stopped, :deleted, :failed],
      disk_present: state != :deleted,
      cleanup_complete: state == :deleted,
      reason: if(state == :unknown, do: :unknown, else: reason)
    }
  end
end
