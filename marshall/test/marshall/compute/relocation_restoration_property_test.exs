defmodule Marshall.Compute.RelocationRestorationPropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures

  alias Marshall.Compute.{
    Credentials,
    Host,
    Ledger,
    Operation,
    ProvisionerControl,
    Relocation,
    RelocationCapacity,
    RelocationCoordinator,
    RelocationRevocations,
    Reservation,
    VirtualMachine
  }

  @moduletag timeout: 180_000

  # @cc [owner:ghuntley,label:verification;recovery;capacity] generated-memory-restoration-authority
  # Unknown pause/resume observations MUST retain cancellation authority and all
  # reservations. Only an exact physical pause permits one checkpoint resume.
  # Failed or ambiguous resume MUST NOT replay RAM or create a cold start, even
  # after the old cold-retry window expires. Seeded receipts establish BEAM
  # coordination, never physical snapshot retention or multi-host continuity.
  property "generated uncertainty retains one memory restoration without cold replay",
    test_cases: 8,
    seed: 2_026_101_804 do
    pause_unknowns = draw("unknown pause receipts", integer(1..3))
    resume_unknowns = draw("unknown resume receipts", integer(1..3))
    failure = draw("restore fails after ambiguous receipts", boolean())
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)

    try do
      c = fixture()
      journey(c, pause_unknowns, resume_unknowns, failure)
    after
      :ok = Ecto.Adapters.SQL.Sandbox.checkin(Marshall.Repo)
    end
  end

  @type context :: %{
          vm: VirtualMachine.t(),
          relocation: Relocation.t(),
          owner: Marshall.Accounts.User.t(),
          token: String.t(),
          session: map()
        }

  # @cc [owner:ghuntley,label:verification;security;capacity] evacuation-source-restoration-capacity-scope
  # Active or paused campaign cancellation MUST resume the exact original
  # checkpoint on its retained source while generic wake admission stays closed.
  # Other maintenance modes, disabled hosts, stale/insufficient telemetry and
  # changed checkpoint or execution identity MUST refuse this exception.
  for status <- [:active, :paused] do
    test "cancelled #{status} evacuation resumes only its original retained source" do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)

      try do
        c = fixture(unquote(status))
        journey(c, 1, 1, false)
      after
        :ok = Ecto.Adapters.SQL.Sandbox.checkin(Marshall.Repo)
      end
    end
  end

  @spec fixture(:active | :paused | nil) :: context()
  defp fixture(evacuation_status \\ nil) do
    source = host_fixture()
    owner = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    Ledger.update!(operation, :complete, %{})
    vm = Ledger.update!(vm, :observe, %{observed_state: :running})
    _destination = host_fixture()

    {:ok, relocation} =
      Ledger.transaction(fn ->
        hosts =
          Host |> Ledger.read!() |> Enum.sort_by(& &1.id) |> Enum.map(&Ledger.lock!(Host, &1.id))

        vm = Ledger.lock!(VirtualMachine, vm.id)

        if evacuation_status do
          # Synthetic persisted campaign authority exercises the trusted
          # coordinator; public administrator admission is covered separately.
          source_host = Enum.find(hosts, &(&1.id == source.host.id))

          source_host =
            Ledger.update!(source_host, :maintenance, %{
              maintenance_mode: :evacuating,
              enabled: true
            })

          campaign =
            Ledger.create!(Marshall.Compute.Evacuation, :record, %{
              host_id: source_host.id,
              requested_by_id: owner.id
            })

          item =
            Ledger.create!(Marshall.Compute.EvacuationItem, :record, %{
              evacuation_id: campaign.id,
              vm_id: vm.id,
              placement_id: vm.current_placement_id,
              execution_epoch: vm.execution_epoch,
              original_state: :running
            })

          item =
            Ledger.update!(item, :approve, %{approved_at: Ledger.now(), approved_by_id: owner.id})

          hosts =
            Enum.map(hosts, fn host ->
              if host.id == source_host.id, do: source_host, else: host
            end)

          relocation = RelocationCapacity.reserve_evacuation_locked!(vm, hosts, campaign, item)
          if evacuation_status == :paused, do: Ledger.update!(campaign, :pause, %{})
          relocation
        else
          RelocationCapacity.reserve_locked!(vm, hosts, owner, Ash.UUID.generate())
        end
      end)

    {:ok, credential} = Credentials.rotate(source.host.id, 3600)

    {:ok, session} =
      ProvisionerControl.open_execution(credential.token, %{
        session_id: Ash.UUID.generate(),
        machine_id: source.host.machine_id
      })

    %{vm: vm, relocation: relocation, owner: owner, token: credential.token, session: session}
  end

  @spec journey(context(), pos_integer(), pos_integer(), boolean()) :: true
  defp journey(c, pause_unknowns, resume_unknowns, failure) do
    assert c.relocation.preserves_memory

    {:ok, _} =
      Marshall.Compute.cancel_relocation(%{relocation_id: c.relocation.id}, actor: c.owner)

    message = %{session_id: c.session["session_id"], epoch: c.session["epoch"], results: []}
    {:ok, %{"commands" => [wire]}} = RelocationRevocations.exchange(c.token, message)
    {:ok, revoke} = OverallsProtocol.RelocationRevocation.command(wire)

    {:ok, _} =
      RelocationRevocations.exchange(c.token, %{
        message
        | results: [Map.take(revoke, [:id, :placement_id, :execution_epoch])]
      })

    holds = Enum.sort_by(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.id)
    assert {:ok, :restoring_source} = RelocationCoordinator.advance(c.relocation.id)
    [relocation] = Ledger.read!(Relocation, id: c.relocation.id)
    [pause] = Ledger.read!(Operation, id: relocation.cancellation_stop_operation_id)
    assert pause.kind == :pause and pause.execution_epoch == c.vm.execution_epoch + 1

    for _ <- 1..pause_unknowns do
      restoration_outcome(c, pause, :unknown)
      assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)

      assert [%{cancellation_start_operation_id: nil, source_restored_at: nil}] =
               Ledger.read!(Relocation, id: relocation.id)
    end

    restoration_outcome(c, pause, :paused)
    restoration_outcome(c, pause, :unknown)
    assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)
    assert Ledger.read!(Operation, relocation_id: relocation.id, kind: :resume) == []
    restoration_outcome(c, pause, :paused)
    refresh_source_capacity!(c)
    assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)
    [relocation] = Ledger.read!(Relocation, id: relocation.id)
    [resume] = Ledger.read!(Operation, id: relocation.cancellation_start_operation_id)
    assert resume.kind == :resume and resume.generation == pause.generation + 1

    assert resume.command_snapshot["checkpoint"] ==
             OverallsProtocol.Checkpoint.encode(checkpoint(c.vm))

    for _ <- 1..resume_unknowns do
      restoration_outcome(c, resume, :unknown)
      assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)
      assert_one_resume!(c, resume)
    end

    if failure do
      for disk_present <- [false, true] do
        restoration_outcome(c, resume, :failed, disk_present)
        assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)
        assert_one_resume!(c, resume)
      end

      [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

      Ledger.intent!(vm, %{
        crash_restart_times: List.duplicate(DateTime.add(Ledger.now(), -601), 3)
      })

      assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)
      assert_one_resume!(c, resume)

      assert [%{source_restored_at: nil, finished_at: nil}] =
               Ledger.read!(Relocation, id: relocation.id)
    else
      restoration_outcome(c, resume, :running)
      restoration_outcome(c, resume, :unknown)
      assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)
      restoration_outcome(c, resume, :running)

      assert {:ok, :source_restored_pending_cleanup} =
               RelocationCoordinator.advance(relocation.id)

      [restored] = Ledger.read!(Relocation, id: relocation.id)
      assert restored.source_restored_at != nil and restored.finished_at == nil
      assert_one_resume!(c, resume)
    end

    assert holds == Enum.sort_by(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.id)
  end

  @spec refresh_source_capacity!(context()) :: :ok
  defp refresh_source_capacity!(c) do
    {:ok, :ok} =
      Ledger.transaction(fn ->
        host = Ledger.lock!(Host, c.relocation.source_host_id)
        vm = Ledger.lock!(VirtualMachine, c.vm.id)
        [reservation] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
        [pool] = Ledger.read!(Marshall.Compute.StoragePool, id: reservation.pool_id)
        host = Ledger.update!(host, :report, %{reported_at: Ledger.now()})
        Ledger.update!(pool, :report, %{reported_at: Ledger.now()})
        [relocation] = Ledger.read!(Relocation, id: c.relocation.id)

        assert Marshall.Compute.RestartCapacity.check_source_restoration(
                 host,
                 vm,
                 reservation,
                 relocation
               ) == :fits

        if host.maintenance_mode == :evacuating do
          assert Marshall.Compute.RestartCapacity.check(host, vm, reservation) == :insufficient
          assert_restoration_scope!(host, vm, reservation, relocation)
        end

        :ok
      end)

    :ok
  end

  @spec assert_restoration_scope!(Host.t(), VirtualMachine.t(), Reservation.t(), Relocation.t()) ::
          :ok
  defp assert_restoration_scope!(host, vm, reservation, relocation) do
    alias Marshall.Compute.RestartCapacity

    for {mode, enabled} <- [
          {:draining, false},
          {:retired, false},
          {:normal, false},
          {:evacuating, false}
        ] do
      assert RestartCapacity.check_source_restoration(
               %{host | maintenance_mode: mode, enabled: enabled},
               vm,
               reservation,
               relocation
             ) == :insufficient
    end

    for changed <- [
          %{relocation | evacuation_id: nil},
          %{relocation | vm_id: Ash.UUID.generate()},
          %{relocation | finished_at: Ledger.now()},
          %{relocation | source_restored_at: Ledger.now()},
          %{relocation | cancellation_start_operation_id: Ash.UUID.generate()},
          %{relocation | source_host_id: Ash.UUID.generate()},
          %{relocation | source_placement_id: Ash.UUID.generate()},
          %{relocation | destination_epoch: relocation.destination_epoch + 1},
          %{
            relocation
            | cancellation_stop_generation: relocation.cancellation_stop_generation + 1
          },
          %{relocation | source_revoked_at: nil},
          %{relocation | cancellation_requested_at: nil},
          %{relocation | committed_at: Ledger.now()},
          %{relocation | wake_request_id: Ash.UUID.generate()}
        ] do
      assert RestartCapacity.check_source_restoration(host, vm, reservation, changed) ==
               :insufficient
    end

    assert RestartCapacity.check_source_restoration(
             host,
             vm,
             %{reservation | compute_held: false},
             relocation
           ) == :insufficient

    stale = %{
      host
      | reported_at:
          DateTime.add(
            Ledger.now(),
            -Marshall.Compute.HostLiveness.capacity_ms() - 1,
            :millisecond
          )
    }

    assert RestartCapacity.check_source_restoration(stale, vm, reservation, relocation) == :stale
    insufficient = %{host | capacity: Map.put(host.capacity, "memory_headroom_bytes", 0)}

    assert RestartCapacity.check_source_restoration(insufficient, vm, reservation, relocation) ==
             :insufficient

    incompatible = %{
      host
      | inventory:
          Map.put(
            host.inventory,
            "checkpoint_compatibility",
            "sha256:" <> String.duplicate("e", 64)
          )
    }

    assert RestartCapacity.check_source_restoration(incompatible, vm, reservation, relocation) ==
             :insufficient

    :ok
  end

  @spec assert_one_resume!(context(), Operation.t()) :: true
  defp assert_one_resume!(c, resume) do
    assert [resume.id] ==
             Enum.map(
               Ledger.read!(Operation, relocation_id: c.relocation.id, kind: :resume),
               & &1.id
             )

    assert Ledger.read!(Operation, relocation_id: c.relocation.id, kind: :start) == []
  end

  @spec restoration_outcome(
          context(),
          Operation.t(),
          :unknown | :paused | :failed | :running,
          boolean()
        ) :: map()
  defp restoration_outcome(c, operation, state, disk_present \\ true) do
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

    outcome = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      generation: operation.generation,
      operation_id: operation.id,
      sequence: vm.outcome_sequence + 1,
      state: state,
      compute_empty: state in [:paused, :failed],
      disk_present: disk_present,
      cleanup_complete: false,
      reason:
        case state do
          :failed -> :execution_failed
          :unknown -> :unknown
          _ -> :none
        end
    }

    outcome =
      if state in [:paused, :running],
        do: Map.put(outcome, :checkpoint, checkpoint(vm)),
        else: outcome

    execution = %{
      session_id: c.session["session_id"],
      epoch: c.session["epoch"],
      report: nil,
      acknowledgements: [],
      outcomes: []
    }

    assert {:ok, _} = ProvisionerControl.exchange_execution(c.token, execution)

    assert {:ok, _} =
             ProvisionerControl.exchange_execution(c.token, %{execution | outcomes: [outcome]})

    outcome
  end

  @spec checkpoint(VirtualMachine.t()) :: OverallsProtocol.Checkpoint.t()
  defp checkpoint(vm) do
    %{
      id: "11111111-1111-4111-8111-111111111111",
      memory_bytes: vm.memory_bytes,
      state_bytes: 4096,
      compatibility: "sha256:" <> String.duplicate("a", 64),
      memory_sha256: "sha256:" <> String.duplicate("b", 64),
      state_sha256: "sha256:" <> String.duplicate("c", 64),
      manifest_sha256: "sha256:" <> String.duplicate("d", 64),
      dataset_guid: "81",
      snapshot_guid: "82"
    }
  end
end
