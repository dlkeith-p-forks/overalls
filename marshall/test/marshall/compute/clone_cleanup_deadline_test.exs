defmodule Marshall.Compute.CloneCleanupDeadlineTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Compute
  alias Marshall.Compute.{CloneCoordinator, CloneGuard, CloneRequest, Ledger, Operation}
  alias Marshall.Compute.{Reservation, TransferSlot}

  @moduletag timeout: 180_000

  # @cc [owner:ghuntley,label:verification;recovery] clone-cleanup-deadline-tested
  # A published, restored, settled and quiescent request whose prune stays
  # unconfirmed MUST complete at its deadline with the copy usable, the slots
  # released, the source hold and exclusion retained and the prune still
  # offered; another machine's clone on the host MUST activate meanwhile, a
  # same-source request MUST wait as source_cleanup_pending, and the prune
  # receipt MUST settle the hold and wake the waiting request.
  property "cleanup deadline completes the copy but keeps the source hold until prune confirms",
    test_cases: 6 do
    check all(attempts <- integer(1..3), same_source_first? <- boolean(), test_cases: 6) do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)
      previous = Application.get_env(:marshall, :clone_cleanup_deadline_ms)
      Application.put_env(:marshall, :clone_cleanup_deadline_ms, 1)
      # Outcome events are informational; the test logger level hides them.
      Logger.configure(level: :info)

      try do
        fixture = host_fixture()
        actor = user()
        {:ok, vm} = Compute.provision(request(), actor: actor)
        c = Map.merge(fixture, %{actor: actor, vm: vm})

        # Enough compute for the source, two copies and a restart hold at once.
        report = %{
          c.report
          | effective_cores: 16,
            effective_memory_bytes: 17_179_869_184,
            capacity: %{
              c.report.capacity
              | "cpu_headroom_millicores" => 16_000,
                "memory_headroom_bytes" => 17_179_869_184
            },
            pools:
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

        {:ok, other_vm} = Compute.provision(request(), actor: c.actor)
        [other_boot] = Ledger.read!(Operation, vm_id: other_vm.id)
        assert {:ok, _} = ingest(other_vm, other_boot, 1, :running)

        {:ok, other_stop} =
          Compute.lifecycle(
            %{vm_id: other_vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
            actor: c.actor
          )

        assert {:ok, _} = ingest(other_vm, other_stop, 2, :stopped)

        {:ok, clone} =
          Compute.clone(%{vm_id: c.vm.id, idempotency_key: Ash.UUID.generate()}, actor: c.actor)

        advance(clone)
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
          receive_effect(clone, kind, result, connection)
          advance(clone)
        end

        [stop] = Ledger.read!(Operation, id: record(clone).source_operation_id)
        assert {:ok, _} = ingest(c.vm, stop, 2, :stopped)
        advance(clone)

        descriptor =
          Map.put(Marshall.Compute.CloneEffects.intent(record(clone)), "stream", %{
            "source_dataset_guid" => "100",
            "to_guid" => "101"
          })

        receive_effect(clone, :capture, %{"descriptor" => descriptor}, connection)
        advance(clone)
        [restart] = Ledger.read!(Operation, id: record(clone).source_operation_id)
        assert {:ok, _} = ingest(c.vm, restart, 3, :running)
        advance(clone)
        assert record(clone).source_restored_at
        receive_effect(clone, :copy, %{"dataset_guid" => "102"}, connection)
        advance(clone)
        receive_effect(clone, :adopt, %{}, connection)
        advance(clone)
        published = record(clone)
        assert published.phase == :cleaning and published.published_at
        assert published.cleanup_deadline_at
        assert held_slots(clone) != []

        receive_effect(clone, :revoke, %{}, connection)
        advance(clone)
        assert held_slots(clone) == []
        assert record(clone).active and record(clone).phase == :cleaning
        refute CloneGuard.host_busy?(c.host.id)

        # The prune keeps failing with a closed reason while the destination
        # has not settled: the request waits, labelled with the step and reason.
        for _ <- 1..attempts do
          receive_effect(
            clone,
            :prune,
            %{"error" => "unconfirmed", "reason" => "storage_busy"},
            connection
          )

          advance(clone)
          current = record(clone)
          assert current.phase == :cleaning and current.active
          assert current.failure == "prune_storage_busy"
        end

        [prune] =
          Ledger.read!(Marshall.Compute.CloneEffect, clone_request_id: clone.id, kind: :prune)

        assert prune.unconfirmed_count == attempts and prune.unconfirmed_reason == "storage_busy"

        {:ok, same_source} =
          Compute.clone(%{vm_id: c.vm.id, idempotency_key: Ash.UUID.generate()}, actor: c.actor)

        {:ok, other} =
          Compute.clone(%{vm_id: other_vm.id, idempotency_key: Ash.UUID.generate()},
            actor: c.actor
          )

        # Activation needs fresh capacity; the fixture report has aged out.
        assert {:ok, :ok} =
                 Marshall.Compute.HostReports.ingest(c.host.id, reply["epoch"], %{
                   report
                   | sequence: report.sequence + 2,
                     sampled_at: Ledger.now()
                 })

        assert {:ok, :preparing} = CloneCoordinator.advance(other.id)
        assert record(other).active and held_slots(other) != []
        # Not the head while the first request is active: it simply waits.
        assert {:ok, :queued} = CloneCoordinator.advance(same_source.id)
        refute record(same_source).active

        [destination] = Ledger.read!(Marshall.Compute.VirtualMachine, id: clone.destination_vm_id)
        [boot] = Ledger.read!(Operation, id: record(clone).destination_operation_id)
        assert {:ok, _} = ingest(destination, boot, 1, :running)
        Process.sleep(5)

        output =
          ExUnit.CaptureLog.capture_log([metadata: [:event, :reason, :effect]], fn ->
            advance(clone)
          end)

        completed = record(clone)
        assert completed.phase == :complete and completed.finished_at
        refute completed.active
        assert completed.cleanup_completed_at == nil
        assert completed.failure == nil and completed.name_released_at
        assert output =~ "event=clone.cleanup_deferred"
        assert output =~ "event=clone.completed"
        assert source_hold(c.vm).temporary_disk_bytes > 0
        assert CloneGuard.vm_busy?(c.vm.id)
        refute CloneGuard.lifecycle_busy?(c.vm.id, :start)
        refute CloneGuard.lifecycle_busy?(clone.destination_vm_id, :start)

        # The same-source request becomes the head and waits for the snapshot.
        same_source_check = fn ->
          assert {:ok, deferred} = CloneCoordinator.advance(same_source.id)

          assert deferred.phase == :queued and
                   deferred.deferred_reason == "source_cleanup_pending"

          refute deferred.active
        end

        if same_source_first?, do: same_source_check.()

        # The prune is still offered to the host after completion.
        assert {:ok, %{"commands" => commands}} =
                 Marshall.Compute.CloneEffects.exchange(elem(connection, 0), elem(connection, 1))

        assert Enum.any?(commands, &(&1["id"] == prune.id and &1["kind"] == "prune"))
        unless same_source_first?, do: same_source_check.()

        output =
          ExUnit.CaptureLog.capture_log([metadata: [:event, :reason, :effect]], fn ->
            receive_effect(clone, :prune, %{}, connection)
            advance(clone)
          end)

        settled = record(clone)
        assert settled.phase == :complete and settled.cleanup_completed_at
        assert source_hold(c.vm).temporary_disk_bytes == 0
        assert output =~ "event=clone.effect_confirmed"
        assert output =~ "event=clone.cleanup_completed"
        refute CloneGuard.vm_busy?(c.vm.id)
        assert {:ok, :finished} = CloneCoordinator.advance(clone.id)

        # The other machine's copy still holds the host slot; drive it through
        # its stream so both revocations release the slot for the waiting request.
        for {kind, result} <- [
              prepare: %{"public_key" => transfer_endpoint()["host_key"]},
              probe: %{},
              connect: %{}
            ] do
          receive_effect(other, kind, result, connection)
          advance(other)
        end

        other_descriptor =
          Map.put(Marshall.Compute.CloneEffects.intent(record(other)), "stream", %{
            "source_dataset_guid" => "200",
            "to_guid" => "201"
          })

        receive_effect(other, :capture, %{"descriptor" => other_descriptor}, connection)
        advance(other)
        receive_effect(other, :copy, %{"dataset_guid" => "202"}, connection)
        advance(other)
        receive_effect(other, :adopt, %{}, connection)
        advance(other)
        assert record(other).phase == :cleaning
        assert {:ok, waiting} = CloneCoordinator.advance(same_source.id)
        assert waiting.phase == :queued and waiting.deferred_reason == "transfer_busy"
        receive_effect(other, :revoke, %{}, connection)
        advance(other)
        assert held_slots(other) == []

        assert {:ok, :ok} =
                 Marshall.Compute.HostReports.ingest(c.host.id, reply["epoch"], %{
                   report
                   | sequence: report.sequence + 3,
                     sampled_at: Ledger.now()
                 })

        assert {:ok, :preparing} = CloneCoordinator.advance(same_source.id)
        activated = record(same_source)
        assert activated.active and activated.deferred_reason == nil
        assert Enum.all?(Ledger.read!(TransferSlot, clone_request_id: clone.id), & &1.released_at)
        :ok
      after
        Logger.configure(level: :warning)
        Application.put_env(:marshall, :clone_cleanup_deadline_ms, previous || 300_000)
        :ok = Ecto.Adapters.SQL.Sandbox.checkin(Marshall.Repo)
      end
    end
  end

  @spec advance(%{id: String.t()}) :: {:ok, term()}
  defp advance(clone), do: assert({:ok, _} = CloneCoordinator.advance(clone.id))

  @spec record(%{id: String.t()}) :: CloneRequest.t()
  defp record(clone), do: hd(Ledger.read!(CloneRequest, id: clone.id))

  @spec source_hold(Marshall.Compute.VirtualMachine.t()) :: Reservation.t()
  defp source_hold(vm), do: hd(Ledger.read!(Reservation, placement_id: vm.current_placement_id))

  @spec held_slots(map()) :: [TransferSlot.t()]
  defp held_slots(clone),
    do: Ledger.read!(TransferSlot, clone_request_id: clone.id, released_at: [is_nil: true])

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

  @spec receive_effect(map(), atom(), map(), {String.t(), map()}) :: :ok
  defp receive_effect(clone, kind, result, {token, message}) do
    assert {:ok, _} = Marshall.Compute.CloneEffects.exchange(token, message)
    effects = Ledger.read!(Marshall.Compute.CloneEffect, clone_request_id: clone.id, kind: kind)
    assert effects != []

    receipts =
      Enum.map(effects, &%{"id" => &1.id, "kind" => Atom.to_string(kind), "result" => result})

    assert {:ok, %{"acknowledgements" => ids}} =
             Marshall.Compute.CloneEffects.exchange(token, %{message | results: receipts})

    assert Enum.sort(ids) == Enum.sort(Enum.map(effects, & &1.id))
    :ok
  end
end
