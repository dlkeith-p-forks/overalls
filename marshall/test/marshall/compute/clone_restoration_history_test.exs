defmodule Marshall.Compute.CloneRestorationHistoryTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Compute
  alias Marshall.Compute.{CloneCoordinator, CloneRequest, Ledger, Operation, Reservation}

  @moduletag timeout: 180_000

  # @cc [owner:ghuntley,label:verification;recovery] published-clone-cleanup-history
  # Repeated reconciliation and duplicate authenticated receipts MUST keep one
  # destination and retain transfer slots until both endpoint revocations are
  # on record; the source temporary hold stays until pruning and destination
  # settlement. Explicit retry MUST NOT overwrite a newer source generation.
  # Synthetic outcomes prove DB authority, not physical readiness; the
  # cloning-fleet test supplies native evidence. A second stable VM may
  # enqueue while slots are held and is deferred, not failed, allocating
  # nothing until verified release; activation after release MUST NOT change
  # the original first-release timestamps.
  property "published clones retain cleanup authority through failed restoration and replay",
    test_cases: 100 do
    repeats = draw("repeats", integer(1..4))
    duplicates = draw("duplicates", integer(1..4))
    newer? = draw("newer?", boolean())
    destination_first? = draw("destination_first?", boolean())
    competing_attempts = draw("competing_attempts", member_of([1, 2, 4]))
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)

    try do
      fixture = host_fixture()
      actor = user()
      {:ok, vm} = Compute.provision(request(), actor: actor)
      c = Map.merge(fixture, %{actor: actor, vm: vm})
      # Four eventual owned disks plus temporary clone headroom
      # must fit independently of the slot lifecycle under test.
      report = %{
        c.report
        | pools:
            Enum.map(c.report.pools, fn pool ->
              %{
                pool
                | total_bytes: 34_359_738_368,
                  free_bytes: 34_359_738_368,
                  storage: storage_observation(c.pool, 34_359_738_368, 34_359_738_368)
              }
            end)
      }

      assert {:ok, :ok} =
               Marshall.Compute.HostReports.ingest(c.host.id, c.epoch, %{
                 report
                 | sequence: report.sequence + 1,
                   sampled_at: Ledger.now()
               })

      [provision] = Ledger.read!(Operation, vm_id: c.vm.id)
      assert {:ok, _} = ingest(c.vm, provision, 1, :running)

      # A stopped independent workload isolates slot occupancy from
      # the wedged source's failed lifecycle and compute headroom.
      {:ok, competitor_vm} = Compute.provision(request(), actor: c.actor)
      [competitor_boot] = Ledger.read!(Operation, vm_id: competitor_vm.id)
      assert {:ok, _} = ingest(competitor_vm, competitor_boot, 1, :running)

      {:ok, competitor_stop} =
        Compute.lifecycle(
          %{
            vm_id: competitor_vm.id,
            kind: :stop,
            idempotency_key: Ash.UUID.generate()
          },
          actor: c.actor
        )

      assert {:ok, _} = ingest(competitor_vm, competitor_stop, 2, :stopped)
      args = %{vm_id: c.vm.id, idempotency_key: Ash.UUID.generate()}
      {:ok, clone} = Compute.clone(args, actor: c.actor)
      repeat_advance(clone, repeats)
      {:ok, credential} = Marshall.Compute.Credentials.rotate(c.host.id, 3600)
      session = Ash.UUID.generate()

      {:ok, reply} =
        Marshall.Compute.ProvisionerControl.open_execution(
          credential.token,
          %{session_id: session, machine_id: c.host.machine_id}
        )

      connection =
        {credential.token, %{session_id: session, epoch: reply["epoch"], results: []}}

      for {kind, result} <- [
            prepare: %{"public_key" => transfer_endpoint()["host_key"]},
            probe: %{},
            connect: %{}
          ] do
        replay_effect(clone, kind, result, connection, duplicates)
        repeat_advance(clone, repeats)
      end

      [stop] = Ledger.read!(Operation, id: clone_record(clone).source_operation_id)
      assert {:ok, _} = ingest(c.vm, stop, 2, :stopped)
      repeat_advance(clone, repeats)

      snapshot =
        Map.put(Marshall.Compute.CloneEffects.intent(clone_record(clone)), "stream", %{
          "source_dataset_guid" => "100",
          "to_guid" => "101"
        })

      replay_effect(
        clone,
        :capture,
        %{"descriptor" => snapshot},
        connection,
        duplicates
      )

      repeat_advance(clone, repeats)
      [restart] = Ledger.read!(Operation, id: clone_record(clone).source_operation_id)
      assert {:ok, _} = ingest(c.vm, restart, 3, :failed)
      repeat_advance(clone, repeats)
      replay_effect(clone, :copy, %{"dataset_guid" => "102"}, connection, duplicates)
      repeat_advance(clone, repeats)
      replay_effect(clone, :adopt, %{}, connection, duplicates)
      repeat_advance(clone, repeats)
      published = clone_record(clone)
      assert published.published_at && published.phase == :cleaning
      assert published.failure == "source_restart_failed"
      assert published.source_restored_at == nil
      assert_slots_held(clone)

      before_submission = activation_inventory()

      {:ok, competing} =
        Compute.clone(
          %{vm_id: competitor_vm.id, idempotency_key: Ash.UUID.generate()},
          actor: c.actor
        )

      assert competing.phase == :queued
      assert activation_inventory() == before_submission

      for _ <- 1..competing_attempts do
        assert {:ok, deferred} = CloneCoordinator.advance(competing.id)
        assert deferred.phase == :queued and deferred.failure == nil
        assert deferred.deferred_reason == "transfer_busy" and deferred.deferred_at
        refute deferred.active
        assert deferred.destination_vm_id == competing.destination_vm_id
        assert activation_inventory() == before_submission
      end

      [destination] =
        Ledger.read!(Marshall.Compute.VirtualMachine, id: clone.destination_vm_id)

      [boot] = Ledger.read!(Operation, id: published.destination_operation_id)

      # Even a settled destination cannot stand in for restoration evidence.
      if destination_first?,
        do: assert({:ok, _} = ingest(destination, boot, 1, :running))

      repeat_advance(clone, repeats)
      assert_slots_held(clone)
      assert clone_record(clone).source_operation_id == restart.id

      if newer? do
        # Model a newer durable lifecycle intent arriving from another trusted
        # coordinator; the old clone must leave its generation untouched.
        assert {:ok, newer} =
                 Ledger.transaction(fn ->
                   Ledger.lock!(Marshall.Compute.Host, c.host.id)
                   source = Ledger.lock!(Marshall.Compute.VirtualMachine, c.vm.id)

                   Ledger.intent!(source, %{
                     generation: source.generation + 1,
                     desired_state: :stopped,
                     crash_restart_times: []
                   })
                 end)

        assert {:ok, _} = Compute.retry_clone(%{request_id: clone.id}, actor: c.actor)
        repeat_advance(clone, repeats)
        assert clone_record(clone).source_operation_id == restart.id
        assert clone_record(clone).source_restored_at == nil
        [current] = Ledger.read!(Marshall.Compute.VirtualMachine, id: c.vm.id)
        assert current.generation == newer.generation
        assert current.desired_state == :stopped
        assert_slots_held(clone)
      else
        assert {:ok, _} = Compute.retry_clone(%{request_id: clone.id}, actor: c.actor)
        repeat_advance(clone, repeats)

        [retried] =
          Ledger.read!(Operation, id: clone_record(clone).source_operation_id)

        assert retried.generation == restart.generation + 1
        assert {:ok, _} = ingest(c.vm, retried, 4, :running)
        repeat_advance(clone, repeats)
        assert clone_record(clone).source_restored_at
        assert_slots_held(clone)

        assert {:ok, later} =
                 Compute.lifecycle(
                   %{
                     vm_id: c.vm.id,
                     kind: :stop,
                     idempotency_key: Ash.UUID.generate()
                   },
                   actor: c.actor
                 )

        replay_effect(clone, :revoke, %{}, connection, duplicates)
        repeat_advance(clone, repeats)
        # Both revocations end the stream: slots release now, the source
        # hold waits for the prune receipt, and the request stays active.
        assert held_slots(clone) == []
        released = clone_slots(clone)
        assert released != [] and Enum.all?(released, & &1.released_at)
        assert clone_record(clone).active and clone_record(clone).phase == :cleaning
        assert source_hold(c.vm).temporary_disk_bytes > 0
        replay_effect(clone, :prune, %{}, connection, duplicates)
        repeat_advance(clone, repeats)
        assert clone_slots(clone) == released

        unless destination_first? do
          assert clone_record(clone).active
          assert {:ok, _} = ingest(destination, boot, 1, :running)
        end

        repeat_advance(clone, repeats)
        assert clone_record(clone).phase == :complete
        assert clone_record(clone).cleanup_completed_at
        assert source_hold(c.vm).temporary_disk_bytes == 0
        assert clone_slots(clone) == released

        assert {:ok, :ok} =
                 Marshall.Compute.HostReports.ingest(c.host.id, reply["epoch"], %{
                   report
                   | sequence: report.sequence + 2,
                     sampled_at: Ledger.now()
                 })

        assert {:ok, :preparing} = CloneCoordinator.advance(competing.id)
        activated = clone_record(competing)
        assert activated.active and activated.phase == :preparing
        assert activated.destination_vm_id == competing.destination_vm_id

        assert [_] =
                 Ledger.read!(Marshall.Compute.VirtualMachine,
                   id: competing.destination_vm_id
                 )

        assert held_slots(competing) != []
        competitor_allocations = activation_inventory()
        repeat_advance(clone, repeats)
        assert clone_slots(clone) == released
        assert activation_inventory() == competitor_allocations
        [current] = Ledger.read!(Marshall.Compute.VirtualMachine, id: c.vm.id)

        assert current.generation == later.generation &&
                 current.desired_state == :stopped
      end

      assert {:ok, replay} = Compute.clone(args, actor: c.actor)

      assert replay.id == clone.id &&
               replay.destination_vm_id == clone.destination_vm_id

      assert clone_record(clone).snapshot == %{"descriptor" => snapshot}

      assert length(
               Ledger.read!(Marshall.Compute.VirtualMachine,
                 id: clone.destination_vm_id
               )
             ) == 1

      assert length(
               Ledger.read!(Marshall.Compute.CloneEffect,
                 clone_request_id: clone.id,
                 kind: :capture
               )
             ) == 1

      :ok
    after
      :ok = Ecto.Adapters.SQL.Sandbox.checkin(Marshall.Repo)
    end
  end

  @spec advance(%{id: String.t()}) :: {:ok, term()}
  defp advance(clone), do: assert({:ok, _} = CloneCoordinator.advance(clone.id))

  @spec clone_record(%{id: String.t()}) :: CloneRequest.t()
  defp clone_record(clone), do: hd(Ledger.read!(CloneRequest, id: clone.id))

  @spec ingest(
          Marshall.Compute.VirtualMachine.t(),
          Operation.t(),
          pos_integer(),
          :running | :stopped | :failed
        ) :: {:ok, [String.t()]} | {:error, atom()}
  defp ingest(vm, op, sequence, state) do
    event = %{
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
      reason: if(state == :failed, do: :execution_failed, else: :none)
    }

    {:ok, event} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    Ledger.transaction(fn ->
      Ledger.lock!(Marshall.Compute.Host, vm.host_id)
      Marshall.Compute.Outcomes.ingest_locked!(vm.host_id, [event])
    end)
  end

  @type activation_inventory :: {
          [Marshall.Compute.VirtualMachine.t()],
          [Marshall.Compute.WorkloadPlacement.t()],
          [Reservation.t()],
          [Marshall.Compute.NetworkAddress.t()],
          [Operation.t()],
          [Marshall.Compute.TransferSlot.t()]
        }

  @spec activation_inventory() :: activation_inventory()
  defp activation_inventory do
    {
      Enum.sort_by(Ledger.read!(Marshall.Compute.VirtualMachine), & &1.id),
      Enum.sort_by(Ledger.read!(Marshall.Compute.WorkloadPlacement), & &1.id),
      Enum.sort_by(Ledger.read!(Reservation), & &1.id),
      Enum.sort_by(Ledger.read!(Marshall.Compute.NetworkAddress), & &1.id),
      Enum.sort_by(Ledger.read!(Operation), & &1.id),
      Enum.sort_by(Ledger.read!(Marshall.Compute.TransferSlot), & &1.id)
    }
  end

  @spec clone_slots(map()) :: [Marshall.Compute.TransferSlot.t()]
  defp clone_slots(clone),
    do:
      Marshall.Compute.TransferSlot
      |> Ledger.read!(clone_request_id: clone.id)
      |> Enum.sort_by(& &1.id)

  @spec repeat_advance(map(), pos_integer()) :: :ok
  defp repeat_advance(clone, count) do
    for _ <- 1..count, do: advance(clone)
    :ok
  end

  @spec source_hold(Marshall.Compute.VirtualMachine.t()) :: Reservation.t()
  defp source_hold(vm), do: hd(Ledger.read!(Reservation, placement_id: vm.current_placement_id))

  @spec held_slots(map()) :: [Marshall.Compute.TransferSlot.t()]
  defp held_slots(clone),
    do:
      Ledger.read!(Marshall.Compute.TransferSlot,
        clone_request_id: clone.id,
        released_at: [is_nil: true]
      )

  @spec assert_slots_held(map()) :: :ok
  defp assert_slots_held(clone) do
    assert held_slots(clone) != []
    assert clone_record(clone).active
    :ok
  end

  @spec replay_effect(map(), atom(), map(), {String.t(), map()}, pos_integer()) :: :ok
  defp replay_effect(clone, kind, result, {token, message}, duplicates) do
    assert {:ok, _} = Marshall.Compute.CloneEffects.exchange(token, message)
    effects = Ledger.read!(Marshall.Compute.CloneEffect, clone_request_id: clone.id, kind: kind)
    assert effects != []

    receipts =
      Enum.map(effects, &%{"id" => &1.id, "kind" => Atom.to_string(kind), "result" => result})

    for _ <- 1..duplicates do
      assert {:ok, %{"acknowledgements" => ids}} =
               Marshall.Compute.CloneEffects.exchange(token, %{message | results: receipts})

      assert Enum.sort(ids) == Enum.sort(Enum.map(effects, & &1.id))
    end

    :ok
  end
end
