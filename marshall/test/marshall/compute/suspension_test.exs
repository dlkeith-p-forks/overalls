defmodule Marshall.Compute.SuspensionTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  import Hegel

  alias Marshall.Compute

  alias Marshall.Compute.{
    Host,
    Idle,
    Ledger,
    Operation,
    Outcomes,
    Relocation,
    Reservation,
    VirtualMachine,
    Wake,
    WakeRequest
  }

  setup do
    source = host_fixture()
    actor = user()
    {:ok, vm} = Compute.provision(request(), actor: actor)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    assert {:ok, _} = observe(vm.host_id, operation, 1, :running)
    %{source: source, actor: actor, vm: current(vm)}
  end

  # @cc [owner:ghuntley,label:verification] suspension-checkpoint-physical-capacity
  # This BEAM test MUST distinguish intent from authenticated physical pause,
  # preserve the full checkpoint in resume authority and refuse a cold start.
  # It establishes control-plane accounting only, never native memory retention.
  test "physical pause frees compute and exact resume retains checkpoint backing", c do
    {:ok, pause} = lifecycle(c, :pause)
    assert hold(c.vm).compute_held

    assert hold(c.vm).checkpoint_bytes ==
             2 * OverallsProtocol.VMShape.checkpoint_bytes(c.vm.memory_bytes)

    checkpoint = checkpoint(c.vm)
    assert {:ok, _} = observe(c.vm.host_id, pause, 2, :paused, checkpoint)
    refute hold(c.vm).compute_held
    assert hold(c.vm).disk_held
    assert current(c.vm).current_checkpoint == OverallsProtocol.Checkpoint.encode(checkpoint)
    assert {:error, error} = lifecycle(c, :start)
    assert Exception.message(error) =~ "machine_paused"

    key = Ash.UUID.generate()
    assert {:ok, wake} = lifecycle(c, :resume, key)
    assert {:ok, replay} = lifecycle(c, :resume, key)
    assert replay.id == wake.id
    joined_key = Ash.UUID.generate()
    assert {:ok, joined} = lifecycle(c, :resume, joined_key)
    assert joined.id == wake.id
    assert {:ok, :waiting} = Wake.advance(wake.id)
    [resume] = Ledger.read!(Operation, vm_id: c.vm.id, kind: :resume)
    assert resume.command_snapshot["checkpoint"] == OverallsProtocol.Checkpoint.encode(checkpoint)
    assert hold(c.vm).compute_held
    assert {:error, :invalid_outcome} = observe(c.vm.host_id, resume, 3, :running)

    assert {:error, :invalid_outcome} =
             observe(c.vm.host_id, resume, 3, :running, %{checkpoint | id: Ash.UUID.generate()})

    assert current(c.vm).observed_state == :paused
    assert [%{status: :resuming, finished_at: nil}] = Ledger.read!(WakeRequest, id: wake.id)
    assert {:ok, _} = observe(c.vm.host_id, resume, 3, :running, checkpoint)
    assert {:ok, :finished} = Wake.advance(wake.id)
    assert [%{status: :ready}] = Ledger.read!(WakeRequest, id: wake.id)
    assert {:ok, joined_replay} = lifecycle(c, :resume, joined_key)
    assert joined_replay.id == wake.id
    assert current(c.vm).current_checkpoint == OverallsProtocol.Checkpoint.encode(checkpoint)
    assert hold(c.vm).checkpoint_bytes > 0
  end

  # @cc [owner:ghuntley,label:verification;security] resume-snapshot-ignores-caller-checkpoint
  # Both built and supplied resume snapshots MUST retain the VM's exact durable
  # continuation. A caller's otherwise valid replacement ID or hash MUST NOT
  # change the checkpoint that Operation.enqueue will dispatch.
  test "supplied resume snapshots cannot replace authoritative checkpoint identity", c do
    pause!(c)
    vm = current(c.vm)

    fields = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      host_id: vm.host_id,
      pool_id: vm.pool_id,
      owner_id: vm.owner_id,
      placement_id: vm.current_placement_id,
      execution_epoch: vm.execution_epoch,
      generation: vm.generation + 1,
      kind: :resume
    }

    snapshot = Marshall.Compute.CommandSnapshot.build(fields)
    assert snapshot["checkpoint"] == vm.current_checkpoint
    operation_fields = Map.drop(fields, [:host_id, :pool_id, :owner_id])

    for {key, replacement} <- [
          {"id", Ash.UUID.generate()},
          {"memory_sha256", "sha256:" <> String.duplicate("e", 64)}
        ] do
      supplied = put_in(snapshot, ["checkpoint", key], replacement)

      changeset =
        Ash.Changeset.for_create(
          Operation,
          :enqueue,
          Map.put(operation_fields, :command_snapshot, supplied),
          actor: Marshall.Authorization.SystemActor.compute()
        )

      assert changeset.valid?

      assert Ash.Changeset.get_attribute(changeset, :command_snapshot)["checkpoint"] ==
               vm.current_checkpoint
    end
  end

  # @cc [owner:ghuntley,label:verification;security] restored-private-services-current-receipt
  # Pending resume may fetch its bootstrap roster, but inference and pulled SSH
  # keys MUST wait for exact physical completion. An older generation MUST fail.
  test "resumed execution regains private services only after physical completion", c do
    {:ok, compute} = Marshall.Compute.Credentials.rotate(c.vm.host_id, 3600)
    connection = Marshall.TerminalFixtures.connect(compute.token, c.source.host.machine_id)

    assert {:ok, _} =
             Marshall.Compute.ProvisionerControl.exchange_execution(
               compute.token,
               Map.merge(connection, %{
                 report: c.source.report,
                 acknowledgements: [],
                 outcomes: []
               })
             )

    pause!(c)
    {:ok, wake} = lifecycle(c, :resume)
    assert {:ok, :waiting} = Wake.advance(wake.id)
    [resume] = Ledger.read!(Operation, vm_id: c.vm.id, kind: :resume)
    vm = current(c.vm)
    {:ok, credential} = Marshall.Inference.Credentials.rotate(vm.host_id, 3600)
    token = credential.id <> "." <> credential.secret

    binding = %{
      "host_id" => vm.host_id,
      "vm_id" => vm.id,
      "placement_id" => vm.current_placement_id,
      "execution_epoch" => vm.execution_epoch
    }

    boot = Map.merge(binding, %{"generation" => vm.generation, "operation_id" => resume.id})
    {:ok, galileo} = Marshall.Galileo.Credentials.rotate(vm.host_id, 3600)
    galileo_token = galileo.id <> "." <> galileo.secret
    name = "resume-services"

    assert {:ok, _} =
             Marshall.Galileo.configure_integration(
               %{
                 name: name,
                 target: "https://example.test",
                 headers: [],
                 peer: false,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.actor
             )

    assert {:ok, _} =
             Marshall.Galileo.attach_integration(%{name: name, vm_id: vm.id}, actor: c.actor)

    integration = %{"binding" => binding, "name" => name}

    assert {:error, :unauthorized} =
             Marshall.Galileo.Authorizations.authorize(galileo_token, integration)

    assert {:ok, %{accounts: [_]}} = Marshall.SSH.GuestAccess.roster(token, boot)
    assert {:error, :unauthorized} = Marshall.SSH.GuestAccess.authorized_keys(token, binding)
    assert {:error, :unauthorized} = Marshall.Inference.Requests.authorize(token, binding)
    # Use the exact checkpoint authorized by this restore, never a replacement.
    {:ok, checkpoint} = OverallsProtocol.Checkpoint.decode(resume.command_snapshot["checkpoint"])
    assert {:ok, _} = observe(vm.host_id, resume, 3, :running, checkpoint)
    assert {:ok, :finished} = Wake.advance(wake.id)
    assert {:ok, %{accounts: [_]}} = Marshall.SSH.GuestAccess.roster(token, boot)
    assert {:ok, %{accounts: [_]}} = Marshall.SSH.GuestAccess.authorized_keys(token, binding)
    assert {:ok, _} = Marshall.Inference.Requests.authorize(token, binding)
    assert {:ok, _} = Marshall.Galileo.Authorizations.authorize(galileo_token, integration)
    assert {:ok, _} = Marshall.Galileo.Authorizations.renew(galileo_token, integration)
    stale = Map.put(boot, "generation", vm.generation - 1)
    assert {:error, :unauthorized} = Marshall.SSH.GuestAccess.roster(token, stale)
  end

  test "failed restore never replays RAM or silently cold boots", c do
    pause!(c)
    {:ok, wake} = lifecycle(c, :resume)
    assert {:ok, :waiting} = Wake.advance(wake.id)
    [resume] = Ledger.read!(Operation, vm_id: c.vm.id, kind: :resume)
    assert {:ok, _} = observe(c.vm.host_id, resume, 3, :failed)
    assert {:ok, :finished} = Wake.advance(wake.id)
    assert [%{status: :failed}] = Ledger.read!(WakeRequest, id: wake.id)
    {:ok, second} = lifecycle(c, :resume)
    assert {:ok, :finished} = Wake.advance(second.id)
    assert length(Ledger.read!(Operation, vm_id: c.vm.id, kind: :resume)) == 1
    assert Ledger.read!(Operation, vm_id: c.vm.id, kind: :start) == []
  end

  test "full fleet retains durable coalesced demand until capacity returns", c do
    pause!(c)
    fill_source!(c.source)
    assert {:ok, wake} = Wake.request(c.vm.id, :network, c.actor)
    assert {:ok, same} = Wake.request(c.vm.id, :prompt, c.actor)
    assert same.id == wake.id
    for _ <- 1..3, do: assert({:ok, :waiting} = Wake.advance(wake.id))

    assert [%{status: :waiting_capacity, finished_at: nil}] =
             Ledger.read!(WakeRequest, id: wake.id)

    assert current(c.vm).observed_state == :paused
    refute hold(c.vm).compute_held
    assert Ledger.read!(Operation, vm_id: c.vm.id, kind: :resume) == []
    assert Ledger.read!(Relocation, vm_id: c.vm.id) == []

    assert {:ok, %Oban.Job{args: %{wake_id: id}}} =
             Marshall.Compute.WakeWorker.new(%{wake_id: wake.id})
             |> Ecto.Changeset.apply_action(:insert)

    assert id == wake.id
    [host] = Ledger.read!(Host, id: c.vm.host_id)
    restored = %{c.source.report | sequence: host.report_sequence + 1, sampled_at: Ledger.now()}
    assert {:ok, :ok} = Marshall.Compute.HostReports.ingest(host.id, c.source.epoch, restored)
    assert {:ok, :waiting} = Wake.advance(wake.id)
    assert [%{status: :resuming}] = Ledger.read!(WakeRequest, id: wake.id)
    assert [%{kind: :resume}] = Ledger.read!(Operation, vm_id: c.vm.id, kind: :resume)
  end

  test "wake uses local capacity before a compatible destination", c do
    pause!(c)
    destination = host_fixture()
    {:ok, wake} = lifecycle(c, :resume)
    assert {:ok, :waiting} = Wake.advance(wake.id)
    [resume] = Ledger.read!(Operation, vm_id: c.vm.id, kind: :resume)
    assert resume.placement_id == c.vm.current_placement_id
    assert Ledger.read!(Relocation, destination_host_id: destination.host.id) == []
  end

  test "local shortage automatically reserves a compatible memory relocation", c do
    pause!(c)
    fill_source!(c.source)
    destination = host_fixture()
    {:ok, wake} = lifecycle(c, :resume)
    assert {:ok, :waiting} = Wake.advance(wake.id)
    assert [relocation] = Ledger.read!(Relocation, vm_id: c.vm.id)
    assert relocation.wake_request_id == wake.id
    assert relocation.requested_by_id == nil
    assert relocation.destination_host_id == destination.host.id
    assert relocation.preserves_memory
    assert relocation.original_state == :running

    assert [%{compute_held: true, checkpoint_bytes: bytes}] =
             Ledger.read!(Reservation, placement_id: relocation.destination_placement_id)

    assert bytes == hold(c.vm).checkpoint_bytes
  end

  test "running network and prompt requests leave the four-hour tool clock alone", c do
    enable_idle!(c.vm, DateTime.add(Ledger.now(), -1000, :second))
    before = current(c.vm)
    assert {:ok, :already_running} = Wake.request(c.vm.id, :network, c.actor)
    assert {:ok, :already_running} = Wake.request(c.vm.id, :prompt, c.actor)
    assert current(c.vm).idle_activity_at == before.idle_activity_at
    assert current(c.vm).idle_revision == before.idle_revision
  end

  test "owner pin defers automatic idle suspension but permits manual pause", c do
    enable_idle!(c.vm, DateTime.add(Ledger.now(), -Idle.seconds(), :second))
    assert {:ok, _pin} = Marshall.Access.pin_machine(%{vm_id: c.vm.id}, actor: c.actor)
    assert {:ok, :deferred} = Idle.suspend(c.vm.id)
    assert {:ok, %{kind: :pause}} = lifecycle(c, :pause)
  end

  test "lifecycle idempotency keys cannot change between wake and stop", c do
    pause!(c)
    key = Ash.UUID.generate()
    {:ok, _wake} = lifecycle(c, :resume, key)
    assert {:error, error} = lifecycle(c, :stop, key)
    assert Exception.message(error) =~ "idempotency_conflict"
    stop_key = Ash.UUID.generate()
    {:ok, _stop} = lifecycle(c, :stop, stop_key)
    assert {:error, error} = lifecycle(c, :resume, stop_key)
    assert Exception.message(error) =~ "idempotency_conflict"
  end

  property "idle deadline is exactly four hours and opt-out never expires" do
    offset = Hegel.draw("elapsed seconds", Hegel.Gen.integer(-172_800..172_800))
    enabled = Hegel.draw("policy enabled", Hegel.Gen.boolean())
    activity = ~U[2026-10-18 00:00:00.000000Z]
    vm = %VirtualMachine{idle_suspend_enabled: enabled, idle_activity_at: activity}

    assert Idle.due?(vm, DateTime.add(activity, offset, :second)) ==
             (enabled and offset >= 14_400)
  end

  @spec lifecycle(map(), :start | :stop | :pause | :resume, String.t()) ::
          {:ok, term()} | {:error, term()}
  defp lifecycle(c, kind, key \\ Ash.UUID.generate()),
    do: Compute.lifecycle(%{vm_id: c.vm.id, kind: kind, idempotency_key: key}, actor: c.actor)

  @spec pause!(map()) :: :ok
  defp pause!(c) do
    {:ok, op} = lifecycle(c, :pause)
    assert {:ok, _} = observe(c.vm.host_id, op, 2, :paused, checkpoint(c.vm))
    :ok
  end

  @spec fill_source!(map()) :: :ok
  defp fill_source!(source) do
    [host] = Ledger.read!(Host, id: source.host.id)

    report = %{
      source.report
      | sequence: host.report_sequence + 1,
        capacity: capacity(1, 1_073_741_824),
        sampled_at: Ledger.now()
    }

    assert {:ok, :ok} = Marshall.Compute.HostReports.ingest(host.id, source.epoch, report)
    :ok
  end

  @spec enable_idle!(VirtualMachine.t(), DateTime.t()) :: :ok
  defp enable_idle!(vm, at) do
    {:ok, :ok} =
      Ledger.transaction(fn ->
        locked = Ledger.lock!(VirtualMachine, vm.id)
        Idle.enable_locked!(locked)

        Ledger.update!(locked, :idle_policy, %{
          idle_suspend_enabled: true,
          idle_activity_at: at,
          idle_revision: 1
        })

        :ok
      end)

    :ok
  end

  @spec current(VirtualMachine.t()) :: VirtualMachine.t()
  defp current(vm), do: Ledger.read!(VirtualMachine, id: vm.id) |> hd()

  @spec hold(VirtualMachine.t()) :: Reservation.t()
  defp hold(vm), do: Ledger.read!(Reservation, placement_id: vm.current_placement_id) |> hd()

  @spec checkpoint(VirtualMachine.t()) :: OverallsProtocol.Checkpoint.t()
  defp checkpoint(vm),
    do: %{
      id: Ash.UUID.generate(),
      memory_bytes: vm.memory_bytes,
      state_bytes: 4096,
      compatibility: "sha256:" <> String.duplicate("a", 64),
      memory_sha256: "sha256:" <> String.duplicate("b", 64),
      state_sha256: "sha256:" <> String.duplicate("c", 64),
      manifest_sha256: "sha256:" <> String.duplicate("d", 64),
      dataset_guid: "71",
      snapshot_guid: "72"
    }

  @spec observe(
          String.t(),
          Operation.t(),
          pos_integer(),
          atom(),
          OverallsProtocol.Checkpoint.t() | nil
        ) :: {:ok, [String.t()]} | {:error, term()}
  defp observe(host, op, sequence, state, checkpoint \\ nil) do
    outcome = %{
      id: Ash.UUID.generate(),
      vm_id: op.vm_id,
      placement_id: op.placement_id,
      execution_epoch: op.execution_epoch,
      operation_id: op.id,
      generation: op.generation,
      sequence: sequence,
      state: state,
      compute_empty: state in [:paused, :stopped, :failed],
      disk_present: true,
      cleanup_complete: false,
      reason: if(state == :failed, do: :execution_failed, else: :none)
    }

    outcome = if checkpoint, do: Map.put(outcome, :checkpoint, checkpoint), else: outcome

    {:ok, typed} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(outcome))

    Ledger.transaction(fn ->
      Ledger.lock!(Host, host)
      Outcomes.ingest_locked!(host, [typed])
    end)
  end
end
