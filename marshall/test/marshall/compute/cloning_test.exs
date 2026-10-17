defmodule Marshall.Compute.CloningTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Compute
  alias Marshall.Compute.{CloneCoordinator, CloneRequest, Ledger, Operation, Reservation}

  setup do
    fixture = host_fixture()
    actor = user()
    {:ok, vm} = Compute.provision(request(), actor: actor)
    Map.merge(fixture, %{actor: actor, vm: vm})
  end

  test "distinct requests queue separate destinations without host effects; retries retain identity",
       c do
    before = Ledger.read!(Operation)
    holds = Ledger.read!(Reservation)
    args = %{vm_id: c.vm.id, idempotency_key: "first"}
    assert {:ok, first} = Compute.clone(args, actor: c.actor)
    assert {:ok, same} = Compute.clone(args, actor: c.actor)
    assert same.id == first.id
    assert same.destination_vm_id == first.destination_vm_id
    assert {:ok, second} = Compute.clone(%{args | idempotency_key: "second"}, actor: c.actor)
    assert second.id != first.id
    assert second.destination_vm_id != first.destination_vm_id
    assert first.queue_position == 1
    assert second.queue_position == 2
    assert Ledger.read!(Operation) == before
    assert Ledger.read!(Reservation) == holds
    assert {:error, _} = Compute.clone(Map.put(args, :name, "different"), actor: c.actor)
    assert length(Ledger.read!(CloneRequest)) == 2
    assert [_ | _] = Marshall.Repo.all(Oban.Job)
  end

  test "clone admission diagnostics cover acceptance and refusal", c do
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    args = %{vm_id: c.vm.id, idempotency_key: Ash.UUID.generate()}

    {{:ok, clone}, accepted} =
      ExUnit.CaptureLog.with_log(
        [metadata: [:event, :vm_id, :clone_id, :destination_vm_id]],
        fn -> Compute.clone(args, actor: c.actor) end
      )

    assert accepted =~ "Clone accepted"
    assert accepted =~ "event=clone.accepted"
    assert accepted =~ "vm_id=" <> c.vm.id
    assert accepted =~ "clone_id=" <> clone.id
    assert accepted =~ "destination_vm_id=" <> clone.destination_vm_id

    {{:ok, _}, replayed} =
      ExUnit.CaptureLog.with_log(
        [metadata: [:event, :vm_id, :clone_id, :destination_vm_id]],
        fn -> Compute.clone(args, actor: c.actor) end
      )

    refute replayed =~ "clone.accepted"

    refused =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :vm_id, :reason]], fn ->
        assert {:error, _} =
                 Compute.clone(%{vm_id: c.vm.id, idempotency_key: Ash.UUID.generate()},
                   actor: user()
                 )
      end)

    assert refused =~ "Clone submission refused"
    assert refused =~ "event=clone.submission_refused"
    assert refused =~ "vm_id=" <> c.vm.id
    assert refused =~ "reason=forbidden"
  end

  test "unauthorized submission and internal Ash mutation are rejected", c do
    args = %{vm_id: c.vm.id, idempotency_key: "no"}
    assert {:error, _} = Compute.clone(args, actor: user())
    assert {:error, _} = Compute.clone(args)

    assert {:error, _} =
             CloneRequest
             |> Ash.Changeset.for_create(:enqueue, %{}, actor: c.actor)
             |> Ash.create()

    assert Ledger.read!(CloneRequest) == []
  end

  test "cancelled queued requests retain replay identity and release names", c do
    args = %{vm_id: c.vm.id, idempotency_key: "cancel", name: "clone-draft"}
    assert {:ok, first} = Compute.clone(args, actor: c.actor)
    assert {:error, _} = Compute.provision(request(%{name: "clone-draft"}), actor: c.actor)
    assert {:ok, cancelled} = Compute.cancel_clone(%{request_id: first.id}, actor: c.actor)
    assert cancelled.phase == :cancelled
    assert {:ok, replay} = Compute.clone(args, actor: c.actor)
    assert replay.id == first.id
    assert replay.phase == :cancelled
    assert {:ok, second} = Compute.clone(%{args | idempotency_key: "next"}, actor: c.actor)
    assert second.id != first.id
    assert second.queue_position == 1
  end

  test "jobs choose the FIFO head and an unsettled source fails without interruption", c do
    assert {:ok, first} =
             Compute.clone(%{vm_id: c.vm.id, idempotency_key: "first"}, actor: c.actor)

    assert {:ok, second} =
             Compute.clone(%{vm_id: c.vm.id, idempotency_key: "second"}, actor: c.actor)

    before = Ledger.read!(Operation)
    assert {:ok, _} = CloneCoordinator.advance(second.id)
    assert {:ok, :queued} = CloneCoordinator.advance(second.id)
    assert {:ok, _} = CloneCoordinator.advance(first.id)
    assert {:ok, first} = Compute.get_clone(%{request_id: first.id}, actor: c.actor)
    assert first.phase == :failed
    assert first.failure == "workload_not_stable"
    assert {:ok, second} = Compute.get_clone(%{request_id: second.id}, actor: c.actor)
    assert second.phase == :queued
    assert Ledger.read!(Operation) == before
  end

  test "activation reserves a separate machine and excludes its premature lifecycle", c do
    [provision] = Ledger.read!(Operation, vm_id: c.vm.id)
    assert {:ok, _} = ingest(c.vm, provision, 1, :running)

    assert {:ok, clone} =
             Compute.clone(%{vm_id: c.vm.id, idempotency_key: "active"}, actor: c.actor)

    assert {:ok, _} = CloneCoordinator.advance(clone.id)
    [request] = Ledger.read!(CloneRequest, id: clone.id)
    assert request.active
    assert request.phase == :preparing
    assert request.original_power_state == :running
    [outcome] = Ledger.read!(Marshall.Compute.PhysicalOutcome, vm_id: c.vm.id)

    coverage = %{
      "execution_epoch" => c.vm.execution_epoch,
      "generation" => c.vm.generation,
      "outcome_id" => outcome.id,
      "compute" => true,
      "disk" => true
    }

    assert {:ok, :ok} =
             Ledger.transaction(fn ->
               host = Ledger.lock!(Marshall.Compute.Host, c.host.id)

               Marshall.Compute.StartupHolds.settle_locked!(
                 %{
                   host
                   | capacity:
                       Map.put(host.capacity, "covered", %{c.vm.current_placement_id => coverage})
                 },
                 [c.pool]
               )
             end)

    [restart_hold] = Ledger.read!(Reservation, placement_id: c.vm.current_placement_id)
    assert restart_hold.startup_compute_held
    [destination] = Ledger.read!(Marshall.Compute.VirtualMachine, id: request.destination_vm_id)
    assert destination.owner_id == c.actor.id
    assert destination.current_placement_id != c.vm.current_placement_id
    assert destination.desired_state == :stopped
    assert Ledger.read!(Operation, vm_id: destination.id) == []

    assert {:error, _} =
             Compute.lifecycle(%{vm_id: destination.id, kind: :start, idempotency_key: "early"},
               actor: c.actor
             )

    assert {:error, _} =
             Compute.lifecycle(%{vm_id: c.vm.id, kind: :delete, idempotency_key: "early-delete"},
               actor: c.actor
             )

    assert {:ok, _} = CloneCoordinator.advance(clone.id)
    [effect] = Ledger.read!(Marshall.Compute.CloneEffect, clone_request_id: clone.id)
    assert effect.kind == :prepare

    assert {:ok, _} =
             OverallsProtocol.DiskTransfer.intent(Marshall.Compute.CloneEffects.intent(request))
  end

  test "queued requester revocation prevents allocation at execution", c do
    [provision] = Ledger.read!(Operation, vm_id: c.vm.id)
    assert {:ok, _} = ingest(c.vm, provision, 1, :running)
    manager = user()

    {:ok, _} =
      Marshall.Access.set_access(
        %{
          vm_id: c.vm.id,
          email: to_string(manager.email),
          role: :manager,
          idempotency_key: "grant"
        },
        actor: c.actor
      )

    assert {:ok, clone} =
             Compute.clone(%{vm_id: c.vm.id, idempotency_key: "revoked"}, actor: manager)

    {:ok, _} =
      Marshall.Access.set_access(
        %{
          vm_id: c.vm.id,
          email: to_string(manager.email),
          role: :revoked,
          idempotency_key: "revoke"
        },
        actor: c.actor
      )

    assert {:ok, _} = CloneCoordinator.advance(clone.id)
    [request] = Ledger.read!(CloneRequest, id: clone.id)
    assert request.phase == :failed
    assert request.failure == "forbidden"
    assert Ledger.read!(Marshall.Compute.VirtualMachine, id: clone.destination_vm_id) == []
  end

  test "durable phase replay captures once, restores before copy, and cleans after publication",
       c do
    [provision] = Ledger.read!(Operation, vm_id: c.vm.id)
    assert {:ok, _} = ingest(c.vm, provision, 1, :running)
    {:ok, clone} = Compute.clone(%{vm_id: c.vm.id, idempotency_key: "workflow"}, actor: c.actor)
    advance(clone)
    advance(clone)
    complete_effect(clone, :prepare, %{"public_key" => transfer_endpoint()["host_key"]})
    advance(clone)
    complete_effect(clone, :probe, %{})
    advance(clone)
    complete_effect(clone, :connect, %{})
    advance(clone)
    request = clone_record(clone)
    [stop] = Ledger.read!(Operation, id: request.source_operation_id)
    assert stop.kind == :stop
    assert {:ok, _} = ingest(c.vm, stop, 2, :stopped)
    advance(clone)
    advance(clone)

    snapshot =
      Map.put(Marshall.Compute.CloneEffects.intent(request), "stream", %{
        "source_dataset_guid" => "100",
        "to_guid" => "101"
      })

    complete_effect(clone, :capture, %{"descriptor" => snapshot})
    advance(clone)
    request = clone_record(clone)
    [restart] = Ledger.read!(Operation, id: request.source_operation_id)
    assert restart.kind == :start
    assert restart.generation > stop.generation
    assert request.phase == :copying
    assert request.snapshot == %{"descriptor" => snapshot}
    assert {:ok, _} = ingest(c.vm, restart, 3, :failed)
    advance(clone)
    assert clone_record(clone).failure == "source_restart_failed"
    [held] = Ledger.read!(Reservation, placement_id: c.vm.current_placement_id)
    assert held.compute_held
    assert {:ok, _} = Compute.retry_clone(%{request_id: clone.id}, actor: c.actor)
    advance(clone)
    [retried] = Ledger.read!(Operation, id: clone_record(clone).source_operation_id)
    assert retried.generation > restart.generation
    assert clone_record(clone).snapshot == %{"descriptor" => snapshot}
    assert {:ok, _} = ingest(c.vm, retried, 4, :running)
    advance(clone)
    assert clone_record(clone).source_restored_at
    # A later source stop is independent of the already captured disk.
    assert {:ok, later_stop} =
             Compute.lifecycle(
               %{vm_id: c.vm.id, kind: :stop, idempotency_key: "later-user-intent"},
               actor: c.actor
             )

    assert later_stop.kind == :stop
    complete_effect(clone, :copy, %{"dataset_guid" => "102"})
    advance(clone)
    advance(clone)
    complete_effect(clone, :adopt, %{})
    advance(clone)
    request = clone_record(clone)
    assert request.published_at
    [destination] = Ledger.read!(Marshall.Compute.VirtualMachine, id: request.destination_vm_id)
    [boot] = Ledger.read!(Operation, id: request.destination_operation_id)
    assert {:ok, _} = ingest(destination, boot, 1, :running)
    assert {:error, _} = Compute.cancel_clone(%{request_id: clone.id}, actor: c.actor)
    advance(clone)
    complete_effect(clone, :revoke, %{})
    advance(clone)
    complete_effect(clone, :prune, %{})
    advance(clone)
    assert clone_record(clone).phase == :complete
    [source] = Ledger.read!(Marshall.Compute.VirtualMachine, id: c.vm.id)
    assert source.generation == later_stop.generation
    assert source.desired_state == :stopped

    assert length(
             Ledger.read!(Marshall.Compute.CloneEffect,
               clone_request_id: clone.id,
               kind: :capture
             )
           ) == 1

    assert Ledger.read!(Marshall.Compute.TransferSlot,
             clone_request_id: clone.id,
             released_at: [is_nil: true]
           ) == []

    [hold] = Ledger.read!(Reservation, placement_id: c.vm.current_placement_id)
    assert hold.temporary_disk_bytes == 0
    advance(clone)
    assert clone_record(clone).snapshot == %{"descriptor" => snapshot}
  end

  test "host receipts require an offered effect and retain late cancellation evidence", c do
    [provision] = Ledger.read!(Operation, vm_id: c.vm.id)
    assert {:ok, _} = ingest(c.vm, provision, 1, :running)
    {:ok, clone} = Compute.clone(%{vm_id: c.vm.id, idempotency_key: "receipts"}, actor: c.actor)
    advance(clone)
    [prepare] = Ledger.read!(Marshall.Compute.CloneEffect, clone_request_id: clone.id)
    {:ok, credential} = Marshall.Compute.Credentials.rotate(c.host.id, 3600)
    session = Ash.UUID.generate()

    {:ok, reply} =
      Marshall.Compute.ProvisionerControl.open_execution(
        credential.token,
        %{session_id: session, machine_id: c.host.machine_id}
      )

    message = %{session_id: session, epoch: reply["epoch"], results: []}

    result = %{
      "id" => prepare.id,
      "kind" => "prepare",
      "result" => %{"public_key" => transfer_endpoint()["host_key"]}
    }

    assert {:error, :invalid_outcome} =
             Marshall.Compute.CloneEffects.exchange(
               credential.token,
               %{message | results: [result]}
             )

    assert {:ok, %{"commands" => [command]}} =
             Marshall.Compute.CloneEffects.exchange(credential.token, message)

    assert command["id"] == prepare.id

    assert {:error, :stale_connection} =
             Marshall.Compute.CloneEffects.exchange(
               credential.token,
               %{message | session_id: Ash.UUID.generate()}
             )

    assert {:ok, _} = Compute.cancel_clone(%{request_id: clone.id}, actor: c.actor)

    assert {:ok, %{"acknowledgements" => [id]}} =
             Marshall.Compute.CloneEffects.exchange(
               credential.token,
               %{message | results: [result]}
             )

    assert id == prepare.id

    assert {:ok, _} =
             Marshall.Compute.CloneEffects.exchange(credential.token, %{
               message
               | results: [result]
             })

    assert clone_record(clone).cancel_requested_at
    assert clone_record(clone).published_at == nil

    conflict =
      put_in(
        result,
        ["result", "public_key"],
        "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 2::256>>)
      )

    assert {:error, :outcome_conflict} =
             Marshall.Compute.CloneEffects.exchange(
               credential.token,
               %{message | results: [conflict]}
             )
  end

  test "only owners and managers may clone, and a manager's copy is private to that manager", c do
    [provision] = Ledger.read!(Operation, vm_id: c.vm.id)
    assert {:ok, _} = ingest(c.vm, provision, 1, :running)

    for role <- [:web, :viewer, :operator, :manager] do
      actor = user()

      assert {:ok, _} =
               Marshall.Access.set_access(
                 %{
                   vm_id: c.vm.id,
                   email: to_string(actor.email),
                   role: role,
                   idempotency_key: Atom.to_string(role)
                 },
                 actor: c.actor
               )

      result =
        Compute.clone(%{vm_id: c.vm.id, idempotency_key: Atom.to_string(role)}, actor: actor)

      if role == :manager do
        assert {:ok, clone} = result
        advance(clone)
        [destination] = Ledger.read!(Marshall.Compute.VirtualMachine, id: clone.destination_vm_id)
        assert destination.owner_id == actor.id
        assert Ledger.read!(Marshall.Access.Grant, vm_id: destination.id) == []
        assert {:error, _} = Compute.get_clone(%{request_id: clone.id}, actor: c.actor)
      else
        assert {:error, _} = result

        for kind <- [:stop, :delete] do
          assert {:error, _} =
                   Compute.lifecycle(
                     %{vm_id: c.vm.id, kind: kind, idempotency_key: Atom.to_string(kind)},
                     actor: actor
                   )
        end
      end
    end
  end

  test "an originally stopped source stays fenced until its immutable capture", c do
    [provision] = Ledger.read!(Operation, vm_id: c.vm.id)
    assert {:ok, _} = ingest(c.vm, provision, 1, :running)

    {:ok, stop} =
      Compute.lifecycle(%{vm_id: c.vm.id, kind: :stop, idempotency_key: "stop-first"},
        actor: c.actor
      )

    assert {:ok, _} = ingest(c.vm, stop, 2, :stopped)
    {:ok, clone} = Compute.clone(%{vm_id: c.vm.id, idempotency_key: "stopped"}, actor: c.actor)
    advance(clone)
    complete_effect(clone, :prepare, %{"public_key" => transfer_endpoint()["host_key"]})
    advance(clone)
    complete_effect(clone, :probe, %{})
    advance(clone)
    complete_effect(clone, :connect, %{})
    advance(clone)
    request = clone_record(clone)
    assert request.phase == :capturing
    assert request.source_restored_at == nil

    assert {:error, _} =
             Compute.lifecycle(%{vm_id: c.vm.id, kind: :start, idempotency_key: "too-early"},
               actor: c.actor
             )

    complete_effect(clone, :capture, %{
      "descriptor" =>
        Map.put(Marshall.Compute.CloneEffects.intent(request), "stream", %{
          "source_dataset_guid" => "100",
          "to_guid" => "101"
        })
    })

    advance(clone)
    assert clone_record(clone).source_restored_at
    assert length(Ledger.read!(Operation, vm_id: c.vm.id)) == 2

    assert {:ok, _} =
             Compute.lifecycle(%{vm_id: c.vm.id, kind: :start, idempotency_key: "after-capture"},
               actor: c.actor
             )

    complete_effect(clone, :copy, %{"dataset_guid" => "102"})
    advance(clone)
    complete_effect(clone, :adopt, %{})
    advance(clone)
    [destination] = Ledger.read!(Marshall.Compute.VirtualMachine, id: clone.destination_vm_id)
    [operation] = Ledger.read!(Operation, vm_id: destination.id)
    assert operation.kind == :stop
    assert destination.desired_state == :stopped
    assert {:ok, _} = ingest(destination, operation, 1, :stopped)
    advance(clone)
    complete_effect(clone, :revoke, %{})
    advance(clone)
    complete_effect(clone, :prune, %{})
    advance(clone)
    assert clone_record(clone).phase == :complete
  end

  test "failed destination admission rolls back the source restart and snapshot holds", c do
    [provision] = Ledger.read!(Operation, vm_id: c.vm.id)
    assert {:ok, _} = ingest(c.vm, provision, 1, :running)
    Ledger.update!(c.host, :report, %{capacity: capacity(3), reported_at: Ledger.now()})
    before_holds = Ledger.read!(Reservation)
    before_operations = Ledger.read!(Operation)

    {:ok, clone} =
      Compute.clone(%{vm_id: c.vm.id, idempotency_key: "no-destination"}, actor: c.actor)

    advance(clone)
    assert clone_record(clone).failure == "insufficient_capacity"
    assert Ledger.read!(Reservation) == before_holds
    assert Ledger.read!(Operation) == before_operations
    assert Ledger.read!(Marshall.Compute.VirtualMachine, id: clone.destination_vm_id) == []
    assert Ledger.read!(Marshall.Compute.TransferSlot, clone_request_id: clone.id) == []
  end

  defp advance(clone), do: assert({:ok, _} = CloneCoordinator.advance(clone.id))
  defp clone_record(clone), do: hd(Ledger.read!(CloneRequest, id: clone.id))

  # Synthetic receipts test coordinator transitions only; native disk evidence is
  # covered by the separate NixOS test and is never inferred from this fixture.
  defp complete_effect(clone, kind, result) do
    effects = Ledger.read!(Marshall.Compute.CloneEffect, clone_request_id: clone.id, kind: kind)
    assert effects != []

    for effect <- effects,
        do: Ledger.update!(effect, :complete, %{result: result, completed_at: Ledger.now()})
  end

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

  test "arbitrary repeated request histories preserve one destination per distinct key", c do
    check all(keys <- list_of(integer(1..8), min_length: 1, max_length: 24), max_runs: 20) do
      prefix = Ash.UUID.generate()

      Enum.reduce(keys, %{}, fn key, model ->
        assert {:ok, result} =
                 Compute.clone(%{vm_id: c.vm.id, idempotency_key: "#{prefix}:#{key}"},
                   actor: c.actor
                 )

        case model[key] do
          nil ->
            refute result.destination_vm_id in Map.values(model)
            Map.put(model, key, result.destination_vm_id)

          id ->
            assert result.destination_vm_id == id
            model
        end
      end)
    end
  end
end
