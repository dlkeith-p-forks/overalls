defmodule Marshall.Compute.ResizeHistoryTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  import Marshall.ComputeFixtures
  alias Marshall.Compute
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes, Reservation, Resize, VirtualMachine}

  @gib 1_073_741_824
  @mib 1_048_576
  @typep shape :: %{vcpu: pos_integer(), memory_bytes: pos_integer(), disk_bytes: pos_integer()}
  @typep history :: %{
           profile: :oss | :customer | :standard | :inception,
           power: :running | :stopped,
           target: shape(),
           unknowns: [non_neg_integer()],
           pressure: boolean(),
           restart_failure: boolean()
         }
  @tables ~w(compute_virtual_machines compute_virtual_machines_versions
             compute_workload_placements compute_reservations compute_network_addresses
             compute_operations compute_physical_outcomes compute_resize_requests
             access_grants access_grants_versions access_changes admin_audit_events)

  # @cc [owner:ghuntley,label:verification;recovery] resize-generated-history-oracle
  # Generated histories MUST use real authorized actions and persisted outcomes.
  # Refusals and exact replays MUST preserve complete durable rows; unknown effects
  # MUST retain holds. Shape expectations MUST include the fixed extra Inception
  # drive and bundle/VMM costs independently of the production accounting helpers.
  property "resize histories preserve identity, evidence boundaries and held resources" do
    previous = Application.get_env(:marshall, :inception_image_id)
    on_exit(fn -> restore_inception(previous) end)

    check all(
            profile <- member_of([:oss, :customer, :standard, :inception]),
            power <- member_of([:running, :stopped]),
            cpu <- integer(1..3),
            memory <- integer(512..1536),
            growth <- integer(1..32),
            unknowns <- list_of(integer(0..2), length: 2),
            pressure <- boolean(),
            restart_failure <- boolean(),
            max_runs: 16
          ) do
      minimum =
        if profile == :inception,
          do: %{vcpu: 16, memory_bytes: 32 * @gib, disk_bytes: 64 * @gib},
          else: %{vcpu: 2, memory_bytes: @gib, disk_bytes: 2 * @gib}

      target = %{
        vcpu: if(profile == :inception, do: 16 + cpu, else: cpu),
        memory_bytes:
          if(profile == :inception, do: 32 * @gib + memory * @mib, else: memory * @mib),
        disk_bytes: minimum.disk_bytes + growth * 4096
      }

      history = %{
        profile: profile,
        power: power,
        target: target,
        unknowns: unknowns,
        pressure: pressure,
        restart_failure: restart_failure
      }

      run_history(history, minimum)
    end
  end

  # @cc [owner:ghuntley,label:verification;security] resize-current-manager-history
  # An original request receipt MUST NOT grant authority after management is
  # downgraded or revoked. Retry authorization follows the current persisted grant;
  # automatic phases retain the retrying actor without changing original ownership.
  property "management transitions fence original request replays and phase retries" do
    check all(
            roles <- list_of(member_of([:manager, :viewer, :revoked]), max_length: 6),
            max_runs: 10
          ) do
      fixture = host_fixture()
      owner = user()
      manager = user()
      assert {:ok, vm} = Compute.provision(request(), actor: owner)
      assert {:ok, _} = ingest(vm, operation(vm), :running)
      grant(vm, owner, manager, :manager)

      args = %{
        vm_id: vm.id,
        expected_generation: current(vm).generation,
        idempotency_key: Ash.UUID.generate(),
        vcpu: 1,
        memory_bytes: @gib,
        disk_bytes: 3 * @gib
      }

      assert {:ok, resize} = Compute.resize(args, actor: manager)
      assert resize.requested_by_id == manager.id

      assert {:ok, _} =
               ingest(vm, operation(vm), :unknown, %{compute_empty: false, reason: :unknown})

      for role <- [:viewer, :manager, :revoked] ++ roles do
        grant(vm, owner, manager, role)

        if role == :manager do
          unchanged(fn ->
            assert {:ok, %{id: id}} = Compute.resize(args, actor: manager)
            assert id == resize.id
          end)

          assert {:ok, _} = Compute.retry_resize(retry_args(vm, resize.id), actor: manager)
          assert operation(vm).requested_by_id == manager.id

          assert {:ok, _} =
                   ingest(vm, operation(vm), :unknown, %{compute_empty: false, reason: :unknown})
        else
          unchanged(fn -> assert {:error, _} = Compute.resize(args, actor: manager) end)

          unchanged(fn ->
            assert {:error, _} = Compute.retry_resize(retry_args(vm, resize.id), actor: manager)
          end)
        end
      end

      assert {:ok, _} = Compute.retry_resize(retry_args(vm, resize.id), actor: owner)
      assert operation(vm).requested_by_id == owner.id
      assert {:ok, _} = ingest(vm, operation(vm), :stopped)
      assert operation(vm).requested_by_id == owner.id
      assert {:ok, _} = ingest(vm, operation(vm), :stopped, %{applied_sizes: resize.target_sizes})
      assert operation(vm).requested_by_id == owner.id
      assert Resize.active(vm.id).requested_by_id == manager.id
      assert {:ok, _} = ingest(vm, operation(vm), :running)
      assert Resize.active(vm.id) == nil
      assert current(vm).owner_id == owner.id
      Ledger.update!(fixture.host, :configure, %{enabled: false})
    end
  end

  @spec grant(
          VirtualMachine.t(),
          Marshall.Accounts.User.t(),
          Marshall.Accounts.User.t(),
          :manager | :viewer | :revoked
        ) :: :ok
  # @cc [owner:ghuntley,label:verification;capacity] resize-restart-awaits-fresh-telemetry
  # Stale capacity telemetry when the disk resize is confirmed MUST neither fail
  # the resize nor release its holds; the next accepted fresh host report MUST
  # enqueue the restart.
  test "a confirmed resize waits for fresh telemetry instead of failing, then restarts" do
    fixture = host_fixture()
    [pool] = fixture.report.pools

    report = fn sequence ->
      %{
        fixture.report
        | sequence: sequence,
          sampled_at: DateTime.utc_now(),
          effective_cores: 64,
          effective_memory_bytes: 128 * @gib,
          capacity: capacity(64, 128 * @gib),
          pools: [
            %{
              pool
              | total_bytes: 1024 * @gib,
                free_bytes: 1024 * @gib,
                storage: storage_observation(fixture.pool, 1024 * @gib, 1024 * @gib)
            }
          ]
      }
    end

    assert {:ok, :ok} =
             Marshall.Compute.HostReports.ingest(fixture.host.id, fixture.epoch, report.(2))

    owner = user()
    source = %{vcpu: 2, memory_bytes: @gib, disk_bytes: 2 * @gib}
    assert {:ok, vm} = Compute.provision(request(Map.put(source, :profile, :oss)), actor: owner)
    assert {:ok, _} = ingest(vm, operation(vm), :running)
    target = %{source | disk_bytes: source.disk_bytes + 4096}

    args =
      Map.merge(target, %{
        vm_id: vm.id,
        expected_generation: current(vm).generation,
        idempotency_key: Ash.UUID.generate()
      })

    assert {:ok, request} = Compute.resize(args, actor: owner)
    assert {:ok, _} = ingest(vm, operation(vm), :stopped)
    assert operation(vm).kind == :resize

    # Telemetry goes stale (a late report) before the resize is confirmed.
    old = DateTime.add(DateTime.utc_now(), -10, :second)
    [host] = Ledger.read!(Host, id: vm.host_id)
    Ledger.update!(host, :report, %{reported_at: old})

    for pool <- Ledger.read!(Marshall.Compute.StoragePool, host_id: vm.host_id),
        do: Ledger.update!(pool, :report, %{reported_at: old})

    assert {:ok, _} = ingest(vm, operation(vm), :stopped, %{applied_sizes: stringify(target)})
    awaiting = Resize.active(vm.id)
    assert awaiting.id == request.id and awaiting.phase == :resizing
    assert awaiting.failure == nil
    assert operation(vm).kind == :resize and operation(vm).status == :completed
    assert reservation(vm).compute_held

    assert {:ok, :ok} =
             Marshall.Compute.HostReports.ingest(fixture.host.id, fixture.epoch, report.(3))

    assert Resize.active(vm.id).phase == :restarting
    assert operation(vm).kind == :start
  end

  defp grant(vm, owner, member, role) do
    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: vm.id,
                 email: to_string(member.email),
                 role: role,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    :ok
  end

  @spec run_history(history(), shape()) :: :ok
  defp run_history(history, source) do
    fixture = host_fixture()
    [pool] = fixture.report.pools

    report = %{
      fixture.report
      | sequence: 2,
        effective_cores: 64,
        effective_memory_bytes: 128 * @gib,
        capacity: capacity(64, 128 * @gib),
        inventory: Map.put(fixture.report.inventory, "inception_image_id", image_id()),
        pools: [
          %{
            pool
            | total_bytes: 1024 * @gib,
              free_bytes: 1024 * @gib,
              storage: storage_observation(fixture.pool, 1024 * @gib, 1024 * @gib)
          }
        ]
    }

    assert {:ok, :ok} =
             Marshall.Compute.HostReports.ingest(fixture.host.id, fixture.epoch, report)

    Application.put_env(
      :marshall,
      :inception_image_id,
      if(history.profile == :inception, do: image_id())
    )

    owner = user()
    outsider = user()
    params = request(Map.merge(source, %{profile: history.profile}))
    assert {:ok, vm} = Compute.provision(params, actor: owner)
    assert {:ok, _} = ingest(vm, operation(vm), :running)

    if history.power == :stopped do
      assert {:ok, stop} =
               Compute.lifecycle(
                 %{vm_id: vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
                 actor: owner
               )

      assert {:ok, _} = ingest(vm, stop, :stopped)
    end

    original = current(vm)
    identity = identity(original)

    args =
      Map.merge(history.target, %{
        vm_id: vm.id,
        expected_generation: original.generation,
        idempotency_key: Ash.UUID.generate()
      })

    for invalid <- [
          Map.put(args, :expected_generation, original.generation + 1),
          Map.put(args, :disk_bytes, source.disk_bytes - 4096),
          Map.put(args, :disk_bytes, 500 * @gib + 4096)
        ] do
      unchanged(fn -> assert {:error, _} = Compute.resize(invalid, actor: owner) end)
    end

    unchanged(fn -> assert {:error, _} = Compute.resize(args, actor: outsider) end)

    unchanged(fn ->
      assert {:error, _} = Compute.resize(Map.merge(args, source), actor: owner)
    end)

    if history.power == :stopped, do: pressure(fixture.host, true)
    assert {:ok, request} = Compute.resize(args, actor: owner)
    assert request.original_sizes == stringify(source)
    assert request.target_sizes == stringify(history.target)
    assert request.original_power_state == history.power

    unchanged(fn ->
      assert {:ok, %{id: id}} = Compute.resize(args, actor: owner)
      assert id == request.id
    end)

    unchanged(fn ->
      assert {:error, _} = Compute.resize(Map.update!(args, :vcpu, &(&1 + 1)), actor: owner)
    end)

    assert sizes(current(vm)) == source
    assert_holds(vm, history.target, source.disk_bytes, history.power == :running)

    for kind <- [:start, :stop, :delete] do
      unchanged(fn ->
        assert {:error, _} =
                 Compute.lifecycle(
                   %{vm_id: vm.id, kind: kind, idempotency_key: Ash.UUID.generate()},
                   actor: owner
                 )
      end)
    end

    [stop_unknowns, resize_unknowns] = history.unknowns

    retry_unknowns(
      vm,
      request.id,
      owner,
      stop_unknowns,
      history.target,
      source.disk_bytes,
      history.power == :running
    )

    assert {:ok, _} = ingest(vm, operation(vm), :stopped)
    assert operation(vm).kind == :resize
    assert operation(vm).command_snapshot["resize_from"] == stringify(source)

    retry_unknowns(
      vm,
      request.id,
      owner,
      resize_unknowns,
      history.target,
      source.disk_bytes,
      history.power == :running
    )

    op = operation(vm)

    for extra <- [
          %{},
          %{applied_sizes: stringify(source)},
          %{applied_sizes: stringify(history.target), placement_id: Ash.UUID.generate()},
          %{applied_sizes: stringify(history.target), execution_epoch: op.execution_epoch + 1}
        ] do
      unchanged(fn -> assert {:error, _} = ingest(vm, op, :stopped, extra) end)
    end

    if history.pressure, do: pressure(fixture.host, true)
    assert {:ok, _} = ingest(vm, op, :stopped, %{applied_sizes: stringify(history.target)})
    assert sizes(current(vm)) == history.target

    assert reservation(vm).disk_bytes ==
             history.target.disk_bytes + @gib + extra_disk(history.profile)

    assert reservation(vm).pending_disk_bytes == 0

    if history.power == :running do
      if history.pressure do
        assert current(vm).desired_state == :stopped
        assert Resize.active(vm.id).failure == "insufficient_capacity"
        refute reservation(vm).compute_held

        unchanged(fn ->
          assert {:error, _} = Compute.retry_resize(retry_args(vm, request.id), actor: owner)
        end)

        pressure(fixture.host, false)
        assert {:ok, _} = Compute.retry_resize(retry_args(vm, request.id), actor: owner)
      end

      if history.restart_failure do
        assert {:ok, _} =
                 ingest(vm, operation(vm), :unknown, %{
                   compute_empty: false,
                   reason: :unknown
                 })

        assert Resize.active(vm.id).phase == :fencing
        assert reservation(vm).compute_held

        unchanged(fn ->
          assert {:error, _} = Compute.retry_resize(retry_args(vm, request.id), actor: owner)
        end)

        assert {:ok, _} = ingest(vm, operation(vm), :stopped)
        assert Resize.active(vm.id).failure == "restart_failed"
        refute reservation(vm).compute_held
        assert {:ok, _} = Compute.retry_resize(retry_args(vm, request.id), actor: owner)
      end

      assert operation(vm).kind == :start
      assert {:ok, _} = ingest(vm, operation(vm), :running)
    else
      refute reservation(vm).compute_held
    end

    assert Resize.active(vm.id) == nil
    assert current(vm).observed_state == history.power
    assert current(vm).desired_state == history.power
    assert identity(current(vm)) == identity

    unchanged(fn ->
      assert {:ok, %{id: id}} = Compute.resize(args, actor: owner)
      assert id == request.id
    end)

    unchanged(fn -> assert {:error, _} = Compute.resize(args, actor: outsider) end)

    unchanged(fn ->
      assert {:ok, replay} = Compute.provision(params, actor: owner)
      assert replay.id == vm.id
      assert sizes(replay) == history.target
    end)

    Ledger.update!(fixture.host, :configure, %{enabled: false})
    :ok
  end

  @spec retry_unknowns(
          VirtualMachine.t(),
          String.t(),
          Marshall.Accounts.User.t(),
          non_neg_integer(),
          shape(),
          pos_integer(),
          boolean()
        ) :: :ok
  defp retry_unknowns(vm, request_id, owner, count, target, disk, running) do
    for _ <- List.duplicate(:retry, count) do
      previous = operation(vm)

      assert {:ok, _} =
               ingest(vm, previous, :unknown, %{compute_empty: false, reason: :unknown})

      assert Resize.active(vm.id).failure == "physical_state_unconfirmed"
      assert_holds(vm, target, disk, running)
      assert {:ok, _} = Compute.retry_resize(retry_args(vm, request_id), actor: owner)
      assert operation(vm).id != previous.id
      assert operation(vm).kind == previous.kind

      assert operation(vm).command_snapshot["resize_from"] ==
               previous.command_snapshot["resize_from"]

      assert_holds(vm, target, disk, running)
      # Valid stale physical receipts remain history but cannot advance intent.
      before = Map.new(inventory()) |> Map.delete("compute_physical_outcomes")
      extra = if previous.kind == :resize, do: %{applied_sizes: stringify(target)}, else: %{}
      assert {:ok, _} = ingest(vm, previous, :stopped, extra)
      assert Map.new(inventory()) |> Map.delete("compute_physical_outcomes") == before
    end

    :ok
  end

  @spec assert_holds(VirtualMachine.t(), shape(), pos_integer(), boolean()) :: :ok
  defp assert_holds(vm, target, disk, running) do
    r = reservation(vm)
    assert r.vcpu == target.vcpu
    assert r.memory_bytes == target.memory_bytes + 64 * @mib
    assert r.disk_bytes == disk + @gib + extra_disk(vm.profile)
    assert r.pending_disk_bytes == target.disk_bytes - disk
    assert r.disk_held
    assert r.compute_held == running
    assert r.startup_compute_held == running
    :ok
  end

  @spec unchanged((-> term())) :: :ok
  defp unchanged(action) do
    before = inventory()
    action.()
    assert inventory() == before
    :ok
  end

  @spec inventory() :: [{String.t(), list()}]
  defp inventory do
    Enum.map(@tables, fn table ->
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "SELECT to_jsonb(r) FROM #{table} r ORDER BY id",
          [],
          log: false
        )

      {table, rows}
    end)
  end

  @spec current(VirtualMachine.t()) :: VirtualMachine.t()
  defp current(vm), do: hd(Ledger.read!(VirtualMachine, id: vm.id))
  @spec operation(VirtualMachine.t()) :: Operation.t()
  defp operation(vm),
    do: hd(Ledger.read!(Operation, vm_id: vm.id, generation: current(vm).generation))

  @spec reservation(VirtualMachine.t()) :: Reservation.t()
  defp reservation(vm), do: hd(Ledger.read!(Reservation, vm_id: vm.id))
  @spec sizes(VirtualMachine.t()) :: shape()
  defp sizes(vm), do: Map.take(vm, [:vcpu, :memory_bytes, :disk_bytes])
  @spec stringify(shape()) :: %{String.t() => pos_integer()}
  defp stringify(shape), do: Map.new(shape, fn {key, value} -> {Atom.to_string(key), value} end)
  @spec extra_disk(atom()) :: non_neg_integer()
  defp extra_disk(:inception), do: 256 * @gib
  defp extra_disk(_), do: 0
  @spec identity(VirtualMachine.t()) :: map()
  defp identity(vm),
    do:
      Map.take(vm, [
        :id,
        :owner_id,
        :team_id,
        :profile,
        :image_id,
        :host_id,
        :pool_id,
        :current_placement_id,
        :execution_epoch,
        :architecture
      ])

  @spec retry_args(VirtualMachine.t(), String.t()) :: map()
  defp retry_args(vm, request_id),
    do: %{vm_id: vm.id, request_id: request_id, expected_generation: current(vm).generation}

  @spec pressure(Host.t(), boolean()) :: Host.t()
  defp pressure(host, true), do: Ledger.update!(host, :report, %{capacity: capacity(0, 0)})

  defp pressure(host, false),
    do: Ledger.update!(host, :report, %{capacity: capacity(64, 128 * @gib)})

  @spec restore_inception(String.t() | nil) :: :ok
  defp restore_inception(nil), do: Application.delete_env(:marshall, :inception_image_id)
  defp restore_inception(value), do: Application.put_env(:marshall, :inception_image_id, value)

  @spec next_sequence(VirtualMachine.t()) :: pos_integer()
  defp next_sequence(vm) do
    Ledger.read!(Marshall.Compute.PhysicalOutcome, vm_id: vm.id)
    |> Enum.map(& &1.sequence)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  @spec ingest(VirtualMachine.t(), Operation.t(), atom(), map()) ::
          {:ok, term()} | {:error, term()}
  defp ingest(vm, operation, state, extra \\ %{}) do
    event =
      Map.merge(
        %{
          id: Ash.UUID.generate(),
          vm_id: vm.id,
          placement_id: operation.placement_id,
          execution_epoch: operation.execution_epoch,
          operation_id: operation.id,
          generation: operation.generation,
          sequence: next_sequence(vm),
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
end
