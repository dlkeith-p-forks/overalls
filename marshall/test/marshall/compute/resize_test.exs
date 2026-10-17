defmodule Marshall.Compute.ResizeTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Compute

  alias Marshall.Compute.{
    Host,
    Image,
    Ledger,
    NetworkAddress,
    Operation,
    Outcomes,
    PhysicalOutcome,
    Reservation,
    Resize,
    ResizeRequest,
    VirtualMachine
  }

  @source %{
    provider: :github,
    namespace: ["octo"],
    repository: "demo",
    revision: %{kind: :default}
  }

  setup context do
    fixture = host_fixture()
    actor = user()
    params = request(Map.take(context, [:workspace_source]))
    {:ok, vm} = Compute.provision(params, actor: actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    assert {:ok, _} = ingest(vm, operation, 1, :running)

    args = %{
      vm_id: vm.id,
      expected_generation: 1,
      idempotency_key: Ash.UUID.generate(),
      vcpu: 1,
      memory_bytes: 1_073_741_824,
      disk_bytes: 3_221_225_472
    }

    Map.merge(fixture, %{actor: actor, vm: vm, params: params, args: args})
  end

  test "exactly 500 GiB is accepted as a resize target", c do
    capacity = 600 * 1_073_741_824
    [pool_report] = c.report.pools

    pool_report = %{
      pool_report
      | total_bytes: capacity,
        free_bytes: capacity,
        storage: storage_observation(c.pool, capacity, capacity)
    }

    report = %{c.report | sequence: 2, pools: [pool_report]}
    assert {:ok, :ok} = Marshall.Compute.HostReports.ingest(c.host.id, c.epoch, report)

    assert {:ok, request} =
             Compute.resize(%{c.args | disk_bytes: 536_870_912_000}, actor: c.actor)

    assert request.target_sizes["disk_bytes"] == 536_870_912_000
  end

  test "durable phases preserve data identity, exact retries and provisioning payload", c do
    assert {:ok, request} = Compute.resize(c.args, actor: c.actor)
    assert request.phase == :stopping
    assert {:ok, same} = Compute.resize(c.args, actor: c.actor)
    assert same.id == request.id
    assert {:error, _} = Compute.resize(%{c.args | vcpu: 3}, actor: c.actor)

    assert {:error, _} =
             Compute.lifecycle(%{vm_id: c.vm.id, kind: :start, idempotency_key: "blocked"},
               actor: c.actor
             )

    assert current(c).vcpu == 2
    assert reservation(c).pending_disk_bytes == 1_073_741_824
    assert reservation(c).startup_compute_held
    stop = operation(c)
    assert {:ok, _} = ingest(c.vm, stop, 2, :stopped)
    assert reservation(c).startup_compute_held
    resize = operation(c)
    assert resize.kind == :resize
    assert resize.command_snapshot["vcpu"] == 1
    assert resize.command_snapshot["resize_from"]["vcpu"] == 2
    assert {:error, :invalid_outcome} = ingest(c.vm, resize, 3, :stopped)
    assert {:ok, _} = ingest(c.vm, resize, 3, :stopped, %{applied_sizes: request.target_sizes})
    assert current(c).disk_bytes == c.args.disk_bytes
    assert current(c).vcpu == 1
    assert reservation(c).pending_disk_bytes == 0
    start = operation(c)
    assert start.kind == :start
    assert {:ok, _} = ingest(c.vm, start, 4, :running)
    assert Resize.active(c.vm.id) == nil
    assert {:ok, replay} = Compute.provision(c.params, actor: c.actor)
    assert replay.id == c.vm.id
    assert replay.vcpu == 1
    assert {:ok, retry} = Compute.resize(c.args, actor: c.actor)
    assert retry.id == request.id
    assert current(c).current_placement_id == c.vm.current_placement_id
  end

  # @cc [owner:ghuntley,label:verification;recovery;security] resize-source-snapshot-authority
  # A real resize restart MUST carry the authoritative source and resize identity
  # even when its coordinator supplies the snapshot. Disabled current capable
  # images remain eligible; existing operation snapshots MUST stay unchanged.
  @tag workspace_source: @source
  test "resize restart pins the recorded source on a disabled capable image", c do
    assert {:ok, request} = Compute.resize(c.args, actor: c.actor)
    assert {:ok, _} = ingest(c.vm, operation(c), 2, :stopped)
    resize = operation(c)
    before = Map.new(Ledger.read!(Operation, vm_id: c.vm.id), &{&1.id, &1.command_snapshot})
    [image] = Ledger.read!(Image, id: c.vm.image_id)
    Ledger.update!(image, :configure, %{enabled: false})

    assert {:ok, _} =
             ingest(c.vm, resize, 3, :stopped, %{applied_sizes: request.target_sizes})

    start = operation(c)
    assert {:ok, command} = OverallsProtocol.Execution.command(start.command_snapshot)
    assert command.workspace_source == @source
    assert command.resize_id == request.id
    assert OverallsProtocol.Resize.sizes(command) == request.target_sizes

    for prior <- Ledger.read!(Operation, vm_id: c.vm.id), Map.has_key?(before, prior.id) do
      assert prior.command_snapshot == Map.fetch!(before, prior.id)
    end

    assert {:ok, _} = ingest(c.vm, start, 4, :running)
    assert Resize.active(c.vm.id) == nil
  end

  # @cc [owner:ghuntley,label:verification;recovery;capacity] resize-source-refusal-preserves-proof
  # Unavailable source capability after a real confirmed resize MUST retain its
  # outcome and target sizes, release only confirmed compute and finish with a
  # fixed failure without a restart operation. Retained disk/address custody and
  # immutable snapshots MUST survive, and ordinary deletion MUST remain possible.
  @tag workspace_source: @source
  test "obsolete source images refuse only resize restart and retain physical proof", c do
    assert {:ok, request} = Compute.resize(c.args, actor: c.actor)
    assert {:ok, _} = ingest(c.vm, operation(c), 2, :stopped)
    resize = operation(c)
    before_operations = Ledger.read!(Operation, vm_id: c.vm.id)
    before_outcomes = Ledger.read!(PhysicalOutcome, vm_id: c.vm.id)
    [address] = Ledger.read!(NetworkAddress, vm_id: c.vm.id)
    [image] = Ledger.read!(Image, id: c.vm.image_id)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE compute_images SET manifest = $1, enabled = false WHERE id = $2",
      [Map.put(image.manifest, "version", 3), image.id]
    )

    assert {:ok, [_]} =
             ingest(c.vm, resize, 3, :stopped, %{applied_sizes: request.target_sizes})

    [finished] = Ledger.read!(ResizeRequest, id: request.id)
    assert finished.phase == :complete
    assert finished.failure == "workspace_source_unavailable"
    assert finished.finished_at != nil
    assert Resize.active(c.vm.id) == nil
    assert current(c).desired_state == :stopped
    assert current(c).observed_state == :stopped
    assert OverallsProtocol.Resize.sizes(current(c)) == request.target_sizes
    refute reservation(c).compute_held
    refute reservation(c).startup_compute_held
    assert reservation(c).disk_held

    assert reservation(c).disk_bytes ==
             OverallsProtocol.VMShape.reservation(current(c)).disk_bytes

    assert reservation(c).pending_disk_bytes == 0
    assert [^address] = Ledger.read!(NetworkAddress, vm_id: c.vm.id)
    assert length(Ledger.read!(PhysicalOutcome, vm_id: c.vm.id)) == length(before_outcomes) + 1
    after_operations = Ledger.read!(Operation, vm_id: c.vm.id)

    assert Enum.sort(Enum.map(after_operations, & &1.id)) ==
             Enum.sort(Enum.map(before_operations, & &1.id))

    for prior <- before_operations do
      [after_operation] = Ledger.read!(Operation, id: prior.id)
      assert after_operation.command_snapshot == prior.command_snapshot
    end

    [confirmed_resize] = Ledger.read!(Operation, id: resize.id)
    assert confirmed_resize.status == :completed
    assert confirmed_resize.completion_outcome_id != nil

    assert {:ok, deletion} =
             Compute.lifecycle(
               %{vm_id: c.vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()},
               actor: c.actor
             )

    assert deletion.kind == :delete
    refute Map.has_key?(deletion.command_snapshot, "workspace_source")
  end

  test "stale, unauthorized, shrink and out-of-bounds requests have no effects", c do
    for args <- [
          %{c.args | expected_generation: 2},
          %{c.args | disk_bytes: 1_073_741_824},
          %{c.args | disk_bytes: 536_870_916_096},
          %{c.args | disk_bytes: 501 * 1_073_741_824},
          %{c.args | vcpu: 0},
          %{c.args | memory_bytes: 1}
        ] do
      assert {:error, _} = Compute.resize(args, actor: c.actor)
    end

    assert {:error, _} = Compute.resize(c.args, actor: user())
    assert {:error, _} = Compute.resize(c.args)
    assert current(c).generation == 1
    assert reservation(c).pending_disk_bytes == 0
    assert [%{kind: :provision}] = Ledger.read!(Operation, vm_id: c.vm.id)
    assert Resize.active(c.vm.id) == nil
  end

  test "stopped machines remain stopped without compute admission", c do
    {:ok, stop} =
      Compute.lifecycle(%{vm_id: c.vm.id, kind: :stop, idempotency_key: "stop"}, actor: c.actor)

    assert {:ok, _} = ingest(c.vm, stop, 2, :stopped)
    Ledger.update!(c.host, :report, %{capacity: capacity(0, 0)})
    assert {:ok, request} = Compute.resize(%{c.args | expected_generation: 2}, actor: c.actor)
    refute reservation(c).compute_held
    assert {:ok, _} = ingest(c.vm, operation(c), 3, :stopped)

    assert {:ok, _} =
             ingest(c.vm, operation(c), 4, :stopped, %{applied_sizes: request.target_sizes})

    assert Resize.active(c.vm.id) == nil
    assert current(c).desired_state == :stopped
    refute reservation(c).compute_held
  end

  test "changed pressure retains confirmed growth and retry resumes restart", c do
    {:ok, request} = Compute.resize(c.args, actor: c.actor)
    assert {:ok, _} = ingest(c.vm, operation(c), 2, :stopped)
    Ledger.update!(c.host, :report, %{capacity: capacity(0, 0)})

    assert {:ok, _} =
             ingest(c.vm, operation(c), 3, :stopped, %{applied_sizes: request.target_sizes})

    assert current(c).desired_state == :stopped
    assert current(c).disk_bytes == c.args.disk_bytes
    assert Resize.active(c.vm.id).failure == "insufficient_capacity"
    args = %{vm_id: c.vm.id, request_id: request.id, expected_generation: current(c).generation}
    assert {:error, _} = Compute.retry_resize(args, actor: c.actor)
    Ledger.update!(c.host, :report, %{capacity: capacity()})
    manager = user()

    {:ok, _} =
      Marshall.Access.set_access(
        %{
          vm_id: c.vm.id,
          email: to_string(manager.email),
          role: :manager,
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.actor
      )

    assert {:ok, _} = Compute.retry_resize(args, actor: manager)
    assert operation(c).kind == :start
    assert operation(c).requested_by_id == manager.id
    assert Resize.active(c.vm.id).requested_by_id == c.actor.id
    assert {:ok, _} = ingest(c.vm, operation(c), 4, :failed, %{reason: :execution_failed})
    assert operation(c).kind == :stop
    assert operation(c).requested_by_id == manager.id
    assert reservation(c).compute_held
    assert {:ok, _} = ingest(c.vm, operation(c), 5, :stopped)
    refute reservation(c).compute_held
    assert Resize.active(c.vm.id).failure == "restart_failed"

    {:ok, _} =
      Marshall.Access.set_access(
        %{
          vm_id: c.vm.id,
          email: to_string(manager.email),
          role: :revoked,
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.actor
      )

    args = %{args | expected_generation: current(c).generation}
    assert {:error, _} = Compute.retry_resize(args, actor: manager)
    assert {:ok, _} = Compute.retry_resize(args, actor: c.actor)
    assert operation(c).requested_by_id == c.actor.id
  end

  test "old running coverage cannot settle the future restart hold and target replaces old hold",
       c do
    [old] = Ledger.read!(Marshall.Compute.PhysicalOutcome, vm_id: c.vm.id)
    {:ok, _} = Compute.resize(c.args, actor: c.actor)

    for generation <- [1, current(c).generation] do
      proof = %{
        "execution_epoch" => 1,
        "generation" => generation,
        "outcome_id" => old.id,
        "compute" => true,
        "disk" => true
      }

      host = %{
        c.host
        | capacity: Map.put(c.host.capacity, "covered", %{c.vm.current_placement_id => proof})
      }

      assert {:ok, :ok} =
               Ledger.transaction(fn ->
                 Ledger.lock!(Host, host.id)
                 Marshall.Compute.StartupHolds.settle_locked!(host, [c.pool])
               end)

      assert reservation(c).startup_compute_held
    end

    [pool] = Ledger.read!(Marshall.Compute.StoragePool, id: c.vm.pool_id)

    available =
      Marshall.Compute.Budget.available(
        c.host,
        pool,
        Ledger.read!(Reservation, host_id: c.host.id)
      )

    assert available.vcpu == 3
    assert {:ok, _} = Compute.provision(request(), actor: c.actor)
    assert {:error, _} = Compute.provision(request(), actor: c.actor)
  end

  test "resize of an existing workload does not require its image catalog entry", c do
    manifest = %{image_manifest() | "minimum_memory_bytes" => 1_073_741_824}
    {:ok, image} = Marshall.Compute.Images.register(manifest, "resize-minimum")
    Ledger.update!(c.host, :report, %{inventory: Map.put(c.host.inventory, "images", [image.id])})

    {:ok, vm} =
      Compute.provision(request(%{image_id: image.id, vcpu: 1, memory_bytes: 1_073_741_824}),
        actor: c.actor
      )

    [op] = Ledger.read!(Operation, vm_id: vm.id)
    assert {:ok, _} = ingest(vm, op, 1, :running)
    Ledger.update!(image, :configure, %{enabled: false})
    Ledger.update!(c.host, :report, %{inventory: Map.put(c.host.inventory, "images", [])})
    args = %{c.args | vm_id: vm.id, vcpu: 1, memory_bytes: 536_870_912}
    assert {:ok, resize} = Compute.resize(args, actor: c.actor)
    assert resize.phase == :stopping
    assert Resize.active(vm.id).id == resize.id

    assert [%{generation: 2, memory_bytes: 1_073_741_824}] =
             Ledger.read!(VirtualMachine, id: vm.id)
  end

  test "immutable command snapshots must match the placement host, pool and VM owner", c do
    original = operation(c)

    assert original.command_snapshot["owner_id"] == c.vm.owner_id

    for field <- ["host_id", "pool_id", "owner_id"] do
      id = Ash.UUID.generate()

      snapshot =
        original.command_snapshot
        |> Map.merge(%{"id" => id, "generation" => 2, "kind" => "stop"})
        |> Map.put(field, Ash.UUID.generate())

      assert_raise Ash.Error.Invalid, fn ->
        Ledger.create!(Operation, :enqueue, %{
          id: id,
          vm_id: c.vm.id,
          placement_id: c.vm.current_placement_id,
          execution_epoch: 1,
          generation: 2,
          kind: :stop,
          requested_by_id: c.actor.id,
          command_snapshot: snapshot
        })
      end
    end

    assert [^original] = Ledger.read!(Operation, vm_id: c.vm.id)
  end

  # @cc [owner:ghuntley,label:verification;security] supplied-snapshot-source-not-authority
  # A valid source supplied in a start snapshot MUST NOT source an unsourced VM.
  # Snapshot authority comes from the VM's durable source record, while operation
  # placement, owner and generation remain independently validated.
  test "a supplied source cannot turn an unsourced machine into a sourced start", c do
    original = operation(c)
    id = Ash.UUID.generate()

    snapshot =
      original.command_snapshot
      |> Map.merge(%{"id" => id, "generation" => 2, "kind" => "start"})
      |> Map.put("workspace_source", OverallsProtocol.WorkspaceSource.encode(@source))

    assert {:ok, start} =
             Ledger.transaction(fn ->
               vm = Ledger.intent!(current(c), %{generation: 2, desired_state: :running})

               Ledger.create!(Operation, :enqueue, %{
                 id: id,
                 vm_id: vm.id,
                 placement_id: vm.current_placement_id,
                 execution_epoch: vm.execution_epoch,
                 generation: vm.generation,
                 kind: :start,
                 requested_by_id: c.actor.id,
                 command_snapshot: snapshot
               })
             end)

    assert {:ok, command} = OverallsProtocol.Execution.command(start.command_snapshot)
    refute Map.has_key?(command, :workspace_source)
    assert command.owner_id == c.vm.owner_id
    assert command.placement_id == c.vm.current_placement_id
    assert command.generation == 2
    assert [^original] = Ledger.read!(Operation, id: original.id)
  end

  # @cc [owner:ghuntley,label:verification;security] supplied-snapshot-immutable-image
  # A sourced start with a valid but foreign image MUST refuse before durable
  # mutation. Source capability checked on the VM image MUST NOT authorize a
  # supplied snapshot to execute an image without the receiver capability.
  @tag workspace_source: @source
  test "a supplied sourced start cannot replace the retained image", c do
    original = operation(c)
    before_vm = current(c)

    {:ok, other} =
      Marshall.Compute.Images.register(
        Map.put(image_manifest(), "workspace_source_version", nil),
        "source-incapable"
      )

    id = Ash.UUID.generate()

    snapshot =
      original.command_snapshot
      |> Map.merge(%{"id" => id, "generation" => 2, "kind" => "start", "image_id" => other.id})

    assert {:ok, supplied} = OverallsProtocol.Execution.command(snapshot)
    assert supplied.workspace_source == @source
    assert supplied.image_id == other.id

    assert {:ok, %{workspace_source_version: nil}} =
             OverallsProtocol.ImageManifest.validate(other.manifest)

    assert_raise Ash.Error.Invalid, fn ->
      Ledger.create!(Operation, :enqueue, %{
        id: id,
        vm_id: c.vm.id,
        placement_id: c.vm.current_placement_id,
        execution_epoch: 1,
        generation: 2,
        kind: :start,
        requested_by_id: c.actor.id,
        command_snapshot: snapshot
      })
    end

    assert current(c) == before_vm
    assert [^original] = Ledger.read!(Operation, vm_id: c.vm.id)
  end

  test "resize diagnostics use catalogued phases and closed atom failure reasons", c do
    {:ok, credential} = Marshall.Compute.Credentials.rotate(c.host.id, 3600)

    {:ok, session} =
      Marshall.Compute.ProvisionerControl.open_execution(
        credential.token,
        %{session_id: Ash.UUID.generate(), machine_id: c.host.machine_id}
      )

    [host] = Ledger.read!(Host, id: c.host.id)

    assert {:ok, :ok} =
             Marshall.Compute.HostReports.ingest(c.host.id, session["epoch"], %{
               c.report
               | sequence: 1,
                 sampled_at: Ledger.now()
             })

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    {{:ok, request}, requested} =
      ExUnit.CaptureLog.with_log([metadata: [:event, :vm_id, :operation_id]], fn ->
        Compute.resize(c.args, actor: c.actor)
      end)

    assert requested =~ "event=vm.resize_requested"
    assert requested =~ "vm_id=" <> c.vm.id
    assert requested =~ "operation_id=" <> request.operation_id

    stopped =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :vm_id, :operation_status]], fn ->
        assert {:ok, _} =
                 exchange(credential.token, host, session, outcome(operation(c), 2, :stopped))
      end)

    assert stopped =~ "event=vm.resize_phase"
    assert stopped =~ "operation_status=resizing"

    Ledger.update!(c.host, :report, %{capacity: capacity(0, 0)})

    failed =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :vm_id, :reason]], fn ->
        assert {:ok, _} =
                 exchange(
                   credential.token,
                   host,
                   session,
                   outcome(operation(c), 3, :stopped, %{applied_sizes: request.target_sizes})
                 )
      end)

    assert failed =~ "event=vm.resize_failed"
    assert failed =~ "reason=insufficient_capacity"
    assert Resize.active(c.vm.id).failure == "insufficient_capacity"
  end

  defp current(c), do: hd(Ledger.read!(VirtualMachine, id: c.vm.id))

  defp operation(c),
    do: hd(Ledger.read!(Operation, vm_id: c.vm.id, generation: current(c).generation))

  defp reservation(c), do: hd(Ledger.read!(Reservation, vm_id: c.vm.id))

  defp ingest(vm, op, sequence, state, extra \\ %{}) do
    event =
      Map.merge(
        %{
          id: Ash.UUID.generate(),
          vm_id: vm.id,
          placement_id: op.placement_id,
          execution_epoch: op.execution_epoch,
          operation_id: op.id,
          generation: op.generation,
          sequence: sequence,
          state: state,
          compute_empty: state != :running,
          disk_present: true,
          cleanup_complete: false,
          reason: :none
        },
        extra
      )

    {:ok, event} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    Ledger.transaction(fn ->
      Ledger.lock!(Host, vm.host_id)
      Outcomes.ingest_locked!(vm.host_id, [event])
    end)
  end

  defp exchange(token, host, session, event) do
    {:ok, event} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    Marshall.Compute.ProvisionerControl.exchange_execution(token, %{
      session_id: host.connection_session_id,
      epoch: session["epoch"],
      report: nil,
      acknowledgements: [],
      outcomes: [event]
    })
  end

  defp outcome(op, sequence, state, extra \\ %{}) do
    Map.merge(
      %{
        id: Ash.UUID.generate(),
        vm_id: op.vm_id,
        placement_id: op.placement_id,
        execution_epoch: op.execution_epoch,
        operation_id: op.id,
        generation: op.generation,
        sequence: sequence,
        state: state,
        compute_empty: state != :running,
        disk_present: true,
        cleanup_complete: false,
        reason: :none
      },
      extra
    )
  end
end
