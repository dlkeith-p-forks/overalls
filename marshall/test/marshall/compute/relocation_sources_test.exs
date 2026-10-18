defmodule Marshall.Compute.RelocationSourcesTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  @endpoint MarshallWeb.Endpoint

  alias Marshall.Compute.{
    Credentials,
    Host,
    Ledger,
    Operation,
    ProvisionerControl,
    RelocationCapacity,
    RelocationSources,
    RelocationReceives,
    Reservation,
    SourcePermitRequest,
    VirtualMachine
  }

  alias OverallsProtocol.RelocationSource, as: Wire

  setup tags do
    if tags[:readiness_mode] in [:timeout, :retry, :retry_delete] do
      previous = Application.get_env(:marshall, :relocation_readiness_timeout_ms)
      Application.put_env(:marshall, :relocation_readiness_timeout_ms, 2000)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:marshall, :relocation_readiness_timeout_ms, previous),
          else: Application.delete_env(:marshall, :relocation_readiness_timeout_ms)
      end)
    end

    source = host_fixture()

    owner = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    Ledger.update!(operation, :complete, %{})
    vm = Ledger.update!(vm, :observe, %{observed_state: :running})
    vm = if tags[:initially_stopped], do: stopped(vm, owner), else: vm
    destination = host_fixture()

    {:ok, relocation} =
      Ledger.transaction(fn ->
        hosts =
          Host |> Ledger.read!() |> Enum.sort_by(& &1.id) |> Enum.map(&Ledger.lock!(Host, &1.id))

        vm = Ledger.lock!(VirtualMachine, vm.id)
        RelocationCapacity.reserve_locked!(vm, hosts, owner, Ash.UUID.generate())
      end)

    relocation =
      if tags[:unprepared_key] do
        relocation
      else
        Ledger.update!(relocation, :record_key, %{
          destination_public_key: transfer_endpoint()["host_key"]
        })
      end

    {vm, relocation} =
      if tags[:stop_pending] do
        # A running source may be paused only with recorded connectivity proof.
        probe = Marshall.RelocationProbeFixture.applied!(relocation, vm)

        vm =
          Ledger.intent!(vm, %{
            desired_state: :paused,
            generation: vm.generation + 1
          })

        operation =
          Ledger.create!(Operation, :enqueue, %{
            vm_id: vm.id,
            placement_id: vm.current_placement_id,
            execution_epoch: vm.execution_epoch,
            generation: vm.generation,
            kind: :pause,
            initiator: :relocation,
            relocation_id: relocation.id
          })

        relocation =
          Ledger.update!(relocation, :record_stop, %{
            source_stop_operation_id: operation.id,
            source_stop_generation: operation.generation,
            source_preflight_request_id: probe.id
          })

        {vm, relocation}
      else
        {vm, relocation}
      end

    {:ok, credential} = Credentials.rotate(source.host.id, 3600)

    {:ok, session} =
      ProvisionerControl.open_execution(
        credential.token,
        %{session_id: Ash.UUID.generate(), machine_id: source.host.machine_id}
      )

    %{
      source: source,
      destination: destination,
      vm: vm,
      relocation: relocation,
      readiness_mode: tags[:readiness_mode],
      owner: owner,
      token: credential.token,
      session: session
    }
  end

  test "full-copy pause requires fresh destination proof and physical checkpoint before snapshots",
       c do
    alias Marshall.Compute.{ProbeRequest, RelocationProbes}
    alias OverallsProtocol.RelocationProbe, as: ProbeWire
    assert {:ok, :waiting} = Marshall.Compute.RelocationCoordinator.advance(c.relocation.id)

    source_message = %{
      session_id: c.session["session_id"],
      epoch: c.session["epoch"],
      results: []
    }

    {:ok, credential} = Credentials.rotate(c.destination.host.id, 3600)

    {:ok, session} =
      ProvisionerControl.open_execution(
        credential.token,
        %{session_id: Ash.UUID.generate(), machine_id: c.destination.host.machine_id}
      )

    destination_message = %{
      session_id: session["session_id"],
      epoch: session["epoch"],
      results: []
    }

    assert {:ok, %{"commands" => []}} =
             RelocationProbes.exchange(credential.token, destination_message)

    assert {:ok, %{"commands" => [grant_wire]}} =
             RelocationProbes.exchange(c.token, source_message)

    assert {:ok, %{"commands" => [^grant_wire]}} =
             RelocationProbes.exchange(c.token, source_message)

    api_body = %{
      "version" => 4,
      "session_id" => source_message.session_id,
      "epoch" => source_message.epoch,
      "results" => []
    }

    {:ok, principal} = Marshall.Control.Services.Lilly.authenticate(c.token)

    assert {:ok, %{"commands" => [^grant_wire]}} =
             Marshall.Control.Services.Lilly.handle_request(
               "lilly.relocation_probe",
               api_body,
               principal
             )

    assert {:ok, grant} = ProbeWire.command(grant_wire)
    assert grant.phase == :grant and grant.source_endpoint == nil
    grant_result = Map.take(grant, [:id, :phase, :challenge, :revision, :expires_at])

    assert {:error, :invalid_outcome} =
             RelocationProbes.exchange(
               credential.token,
               %{destination_message | results: [grant_result]}
             )

    assert {:ok, %{"commands" => [], "acknowledgements" => [grant_id]}} =
             RelocationProbes.exchange(c.token, %{source_message | results: [grant_result]})

    assert grant_id == grant.id

    assert {:ok, :waiting} = Marshall.Compute.RelocationCoordinator.advance(c.relocation.id)

    assert {:ok, %{"commands" => [probe_wire]}} =
             RelocationProbes.exchange(credential.token, destination_message)

    assert {:ok, probe} = ProbeWire.command(probe_wire)
    assert probe.phase == :probe and probe.source_endpoint == c.relocation.source_endpoint
    assert probe.challenge == grant.challenge and probe.expires_at == grant.expires_at
    result = Map.take(probe, [:id, :phase, :challenge, :revision, :expires_at])

    assert {:error, :invalid_outcome} =
             RelocationProbes.exchange(
               credential.token,
               %{destination_message | results: [%{result | phase: :grant}]}
             )

    # Discard already queued coordination so unique-job deduplication cannot
    # hide whether the probe receipt itself schedules the relocation.
    Marshall.Repo.delete_all(
      Ecto.Query.where(Oban.Job, worker: "Marshall.Compute.Workers.CoordinateRelocation")
    )

    assert {:ok, %{"commands" => [], "acknowledgements" => [probe_id]}} =
             RelocationProbes.exchange(credential.token, %{
               destination_message
               | results: [result]
             })

    assert probe_id == probe.id
    [record] = Ledger.read!(ProbeRequest, id: probe.id)
    assert record.applied_at != nil

    # The first probe receipt coordinates immediately: the stop accepts a probe
    # only within its 30-second freshness window, shorter than the cron interval.
    assert coordinations(c.relocation.id) == 1

    assert {:ok, _} =
             RelocationProbes.exchange(credential.token, %{
               destination_message
               | results: [result]
             })

    assert [^record] = Ledger.read!(ProbeRequest, id: probe.id)
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    assert vm.generation == c.vm.generation and vm.desired_state == :running

    assert {:error, :stale_connection} =
             RelocationProbes.exchange(c.token, %{
               source_message
               | epoch: source_message.epoch + 1
             })

    assert {:ok, selected} =
             Ledger.transaction(fn ->
               for host <- Enum.sort([c.source.host.id, c.destination.host.id]),
                   do: Ledger.lock!(Host, host)

               locked = Ledger.lock!(VirtualMachine, c.vm.id)
               now = Ledger.now()

               assert RelocationProbes.ready_request(c.relocation, locked, DateTime.add(now, 31)) ==
                        nil

               assert RelocationProbes.ready_request(
                        c.relocation,
                        %{locked | generation: locked.generation + 1},
                        now
                      ) == nil

               RelocationProbes.ready_request(c.relocation, locked, now)
             end)

    assert selected.id == probe.id
    assert {:ok, :waiting} = Marshall.Compute.RelocationCoordinator.advance(c.relocation.id)

    for host <- [c.source.host, c.destination.host],
        do: Ledger.update!(host, :report, %{reported_at: Ledger.now()})

    assert {:ok, :stopping} = Marshall.Compute.RelocationCoordinator.advance(c.relocation.id)
    assert {:ok, :stopping} = Marshall.Compute.RelocationCoordinator.advance(c.relocation.id)
    [relocation] = Ledger.read!(Marshall.Compute.Relocation, id: c.relocation.id)
    assert relocation.source_preflight_request_id == probe.id
    [operation] = Ledger.read!(Operation, id: relocation.source_stop_operation_id)
    assert operation.kind == :pause and operation.generation == c.vm.generation + 1
    assert {:ok, %{"commands" => []}} = exchange(c)
    restoration_outcome(c, operation, :unknown)
    assert {:ok, %{"commands" => []}} = exchange(c)
    restoration_outcome(c, operation, :paused)
    assert {:ok, %{"commands" => [full_wire]}} = exchange(c)
    assert {:ok, full} = Wire.command(full_wire)
    assert full.generation == operation.generation
    assert full.to_guid == nil
    assert {:ok, %{"commands" => []}} = exchange(c, [reply(full)])

    polling_logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok,
                %{
                  "commands" => [%{"descriptor" => %{"stream" => %{"to_guid" => _}}}]
                }} =
                 RelocationReceives.exchange(credential.token, destination_message)
      end)

    refute polling_logs =~ "event=relocation.receive_recorded"

    stale_logs =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        assert {:error, :stale_connection} =
                 RelocationReceives.exchange(credential.token, %{
                   destination_message
                   | session_id: Ash.UUID.generate()
                 })
      end)

    assert stale_logs =~ "event=relocation.receive_refused"
    assert stale_logs =~ "reason=stale_connection"

    assert Enum.all?(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.disk_held)
    request_delete(c)
    assert {:ok, %{"commands" => []}} = RelocationProbes.exchange(c.token, source_message)

    assert {:ok, %{"commands" => [], "acknowledgements" => [^probe_id]}} =
             RelocationProbes.exchange(credential.token, %{
               destination_message
               | results: [result]
             })
  end

  for initially_stopped <- [false, true],
      stage <- [:before_copy, :snapshot_reported, :restoration_pending, :restored] do
    @tag initially_stopped: initially_stopped
    test "Delete reclaims both copies from #{stage}, initially stopped #{initially_stopped}", c do
      alias Marshall.Compute.{
        Relocation,
        RelocationCoordinator,
        RelocationRevocations,
        RelocationDestinationRevocations,
        RelocationDestinationCleanups,
        RelocationSnapshotCleanups,
        NetworkAddress
      }

      source_message = %{
        session_id: c.session["session_id"],
        epoch: c.session["epoch"],
        results: []
      }

      {:ok, credential} = Credentials.rotate(c.destination.host.id, 3600)

      {:ok, session} =
        ProvisionerControl.open_execution(
          credential.token,
          %{session_id: Ash.UUID.generate(), machine_id: c.destination.host.machine_id}
        )

      destination_message = %{
        session_id: session["session_id"],
        epoch: session["epoch"],
        results: []
      }

      source_result = %{
        id: c.relocation.id,
        placement_id: c.relocation.source_placement_id,
        execution_epoch: c.relocation.source_epoch
      }

      destination_result = %{
        id: c.relocation.id,
        placement_id: c.relocation.destination_placement_id,
        execution_epoch: c.relocation.destination_epoch
      }

      if unquote(stage) == :snapshot_reported do
        if unquote(initially_stopped) do
          {:ok, %{"commands" => [wire]}} = exchange(c)
          {:ok, command} = Wire.command(wire)
          assert {:ok, _} = exchange(c, [reply(command)])
        else
          # A running source is never copied before its recorded pause (ADR-0197).
          assert {:ok, %{"commands" => []}} = exchange(c)
        end
      end

      if unquote(stage) in [:restoration_pending, :restored] do
        assert {:ok, _} =
                 Marshall.Compute.cancel_relocation(%{relocation_id: c.relocation.id},
                   actor: c.owner
                 )

        assert {:ok, %{"commands" => [_]}} =
                 RelocationRevocations.exchange(c.token, source_message)

        assert {:ok, _} =
                 RelocationRevocations.exchange(c.token, %{
                   source_message
                   | results: [source_result]
                 })

        assert {:ok, :restoring_source} = RelocationCoordinator.advance(c.relocation.id)

        if unquote(stage) == :restored do
          quiesce_kind = if c.relocation.preserves_memory, do: :pause, else: :stop
          [stop] = Ledger.read!(Operation, relocation_id: c.relocation.id, kind: quiesce_kind)
          restoration_outcome(c, stop, if(stop.kind == :pause, do: :paused, else: :stopped))

          if c.relocation.original_state == :running do
            assert {:ok, :restoring_source} = RelocationCoordinator.advance(c.relocation.id)
            [start] = Ledger.read!(Operation, relocation_id: c.relocation.id, kind: :resume)
            restoration_outcome(c, start, :running)
          end

          assert {:ok, :source_restored_pending_cleanup} =
                   RelocationCoordinator.advance(c.relocation.id)
        end
      end

      prior_starts = Ledger.read!(Operation, relocation_id: c.relocation.id, kind: :start)
      delete = request_delete(c)
      assert {:ok, :deleting} = RelocationCoordinator.advance(c.relocation.id)
      assert {:ok, :deleting} = RelocationCoordinator.advance(c.relocation.id)
      assert prior_starts == Ledger.read!(Operation, relocation_id: c.relocation.id, kind: :start)
      assert {:ok, %{"commands" => []}} = exchange(c)

      assert {:ok, %{"commands" => [_]}} =
               RelocationSnapshotCleanups.exchange(c.token, source_message)

      [before] = Ledger.read!(VirtualMachine, id: c.vm.id)

      assert before.desired_state == :deleted and
               before.current_placement_id == c.vm.current_placement_id

      unknown = deletion_outcome(c, c.token, source_message, delete, :unknown)
      assert {:ok, :deleting} = RelocationCoordinator.advance(c.relocation.id)
      assert Enum.all?(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.disk_held)

      assert {:ok, _} =
               ProvisionerControl.exchange_execution(
                 c.token,
                 Map.merge(source_message, %{
                   report: nil,
                   acknowledgements: [],
                   outcomes: [unknown]
                 })
               )

      deletion_outcome(c, c.token, source_message, delete, :deleted)
      assert {:ok, :deleting} = RelocationCoordinator.advance(c.relocation.id)
      assert [%{archived_at: nil}] = Ledger.read!(VirtualMachine, id: c.vm.id)
      assert [_] = Ledger.read!(NetworkAddress, vm_id: c.vm.id)

      assert [%{disk_held: false}] =
               Ledger.read!(Reservation, placement_id: c.relocation.source_placement_id)

      assert [%{disk_held: true}] =
               Ledger.read!(Reservation, placement_id: c.relocation.destination_placement_id)

      assert {:ok, _} = RelocationRevocations.exchange(c.token, source_message)

      assert {:ok, _} =
               RelocationRevocations.exchange(c.token, %{
                 source_message
                 | results: [source_result]
               })

      assert {:ok, %{"commands" => [_]}} =
               RelocationDestinationRevocations.exchange(credential.token, destination_message)

      assert {:ok, _} =
               RelocationDestinationRevocations.exchange(
                 credential.token,
                 %{destination_message | results: [destination_result]}
               )

      assert {:ok, :deleting} = RelocationCoordinator.advance(c.relocation.id)
      assert [_] = Ledger.read!(NetworkAddress, vm_id: c.vm.id)

      assert {:ok, %{"commands" => [_]}} =
               RelocationDestinationCleanups.exchange(credential.token, destination_message)

      assert {:ok, _} =
               RelocationDestinationCleanups.exchange(
                 credential.token,
                 %{destination_message | results: [destination_result]}
               )

      assert {:ok, :deleted} = RelocationCoordinator.advance(c.relocation.id)
      assert {:ok, :finished} = RelocationCoordinator.advance(c.relocation.id)
      assert_delete_complete(c, delete)
      assert [%{source_snapshots_cleaned_at: nil}] = Ledger.read!(Relocation, id: c.relocation.id)

      assert {:ok, %{"commands" => [], "acknowledgements" => [_]}} =
               RelocationSnapshotCleanups.exchange(c.token, %{
                 source_message
                 | results: [source_result]
               })

      [first] = Ledger.read!(Relocation, id: c.relocation.id)
      assert first.source_snapshots_cleaned_at != nil

      assert {:ok, _} =
               RelocationSnapshotCleanups.exchange(
                 c.token,
                 %{source_message | results: [source_result]}
               )

      assert [^first] = Ledger.read!(Relocation, id: c.relocation.id)
      assert_delete_complete(c, delete)
      assert [%{deletion_operation_id: id}] = Ledger.read!(Relocation, id: c.relocation.id)
      assert id == delete.id
    end
  end

  defp coordinations(relocation_id) do
    Oban.Testing.all_enqueued(
      repo: Marshall.Repo,
      worker: Marshall.Compute.Workers.CoordinateRelocation
    )
    |> Enum.count(&match?(%{args: %{"primary_key" => %{"id" => ^relocation_id}}}, &1))
  end

  defp request_delete(c) do
    args = %{vm_id: c.vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()}
    assert {:error, _} = Marshall.Compute.lifecycle(args, actor: user())
    assert {:ok, operation} = Marshall.Compute.lifecycle(args, actor: c.owner)
    assert {:ok, retried} = Marshall.Compute.lifecycle(args, actor: c.owner)
    assert operation.id == retried.id
    assert {:error, error} = Marshall.Compute.lifecycle(%{args | kind: :start}, actor: c.owner)
    assert Exception.message(error) =~ "idempotency_conflict"
    operation
  end

  defp deletion_outcome(c, token, session, operation, state) do
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

    execution =
      Map.merge(session, %{report: nil, acknowledgements: [], outcomes: []})
      |> Map.delete(:results)

    assert {:ok, %{"commands" => [wire]}} =
             ProvisionerControl.exchange_execution(token, execution)

    assert wire["id"] == operation.id and wire["kind"] == "delete"

    outcome = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      operation_id: operation.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      generation: operation.generation,
      sequence: vm.outcome_sequence + 1,
      state: state,
      compute_empty: true,
      disk_present: state != :deleted,
      cleanup_complete: state == :deleted,
      reason: if(state == :deleted, do: :none, else: :cleanup_failed)
    }

    assert {:ok, _} =
             ProvisionerControl.exchange_execution(token, %{execution | outcomes: [outcome]})

    outcome
  end

  defp assert_delete_complete(c, operation) do
    assert [] == Ledger.read!(VirtualMachine, id: c.vm.id)
    [vm] = Ledger.history!(VirtualMachine, id: c.vm.id)
    assert vm.archived_at != nil and vm.desired_state == :deleted
    assert [] == Ledger.read!(Marshall.Compute.NetworkAddress, vm_id: c.vm.id)

    assert Enum.all?(Ledger.read!(Reservation, vm_id: c.vm.id), fn hold ->
             not hold.disk_held and not hold.compute_held and hold.temporary_disk_bytes == 0
           end)

    assert {:ok, retried} =
             Marshall.Compute.lifecycle(
               %{vm_id: c.vm.id, kind: :delete, idempotency_key: operation.request_key},
               actor: c.owner
             )

    assert retried.id == operation.id
  end

  for stage <- [
        :before_copy,
        :source_offered,
        :receive_offered,
        :import_offered,
        :import_confirmed
      ] do
    @tag initially_stopped: true
    @tag cancellation_stage: stage
    test "cancellation fences stopped relocation at #{stage} without releasing obligations", c do
      alias Marshall.Compute.{
        Relocation,
        RelocationCoordinator,
        RelocationImports,
        RelocationKeys
      }

      stage = c.cancellation_stage
      holds = Ledger.read!(Reservation, vm_id: c.vm.id)
      {:ok, credential} = Credentials.rotate(c.destination.host.id, 3600)

      {:ok, session} =
        ProvisionerControl.open_execution(
          credential.token,
          %{session_id: Ash.UUID.generate(), machine_id: c.destination.host.machine_id}
        )

      message = %{session_id: session["session_id"], epoch: session["epoch"], results: []}

      command =
        if stage != :before_copy do
          assert {:ok, %{"commands" => [wire]}} = exchange(c)
          {:ok, command} = Wire.command(wire)
          command
        end

      receipt = if command, do: Map.put(reply(command), :dataset_guid, "300")

      if stage in [:receive_offered, :import_offered, :import_confirmed] do
        assert {:ok, _} = exchange(c, [reply(command)])

        assert {:ok, %{"commands" => [_]}} =
                 RelocationReceives.exchange(credential.token, message)
      end

      if stage in [:import_offered, :import_confirmed] do
        assert {:ok, _} =
                 RelocationReceives.exchange(credential.token, %{message | results: [receipt]})

        assert {:ok, %{"commands" => [_]}} = RelocationImports.exchange(credential.token, message)
      end

      if stage == :import_confirmed do
        assert {:ok, _} =
                 RelocationImports.exchange(credential.token, %{message | results: [receipt]})
      end

      assert {:ok, %{"commands" => []}} =
               Marshall.Compute.RelocationDestinationRevocations.exchange(
                 credential.token,
                 message
               )

      assert {:ok, %{"commands" => []}} =
               Marshall.Compute.RelocationDestinationCleanups.exchange(credential.token, message)

      args = %{relocation_id: c.relocation.id}
      assert {:error, _} = Marshall.Compute.cancel_relocation(args, actor: user())
      assert [%{cancellation_requested_at: nil}] = Ledger.read!(Relocation, id: c.relocation.id)
      assert {:ok, cancelled} = Marshall.Compute.cancel_relocation(args, actor: c.owner)
      assert cancelled.cancellation_requested_by_id == c.owner.id
      assert cancelled.cancellation_requested_at != nil and cancelled.finished_at == nil

      result = %{
        id: cancelled.id,
        placement_id: cancelled.destination_placement_id,
        execution_epoch: cancelled.destination_epoch
      }

      assert {:error, :invalid_outcome} =
               Marshall.Compute.RelocationDestinationRevocations.exchange(credential.token, %{
                 message
                 | results: [result]
               })

      assert {:ok, %{"commands" => [revocation_wire]}} =
               Marshall.Compute.RelocationDestinationRevocations.exchange(
                 credential.token,
                 message
               )

      assert {:ok, revoke} =
               OverallsProtocol.RelocationDestinationRevocation.command(revocation_wire)

      assert Map.take(revoke, [:id, :placement_id, :execution_epoch]) == result

      for bad <- [
            %{result | execution_epoch: cancelled.source_epoch},
            %{result | placement_id: cancelled.source_placement_id}
          ] do
        assert {:error, :invalid_outcome} =
                 Marshall.Compute.RelocationDestinationRevocations.exchange(credential.token, %{
                   message
                   | results: [bad]
                 })
      end

      assert {:ok, %{"commands" => [], "acknowledgements" => [_]}} =
               Marshall.Compute.RelocationDestinationRevocations.exchange(credential.token, %{
                 message
                 | results: [result]
               })

      assert {:error, :invalid_outcome} =
               Marshall.Compute.RelocationDestinationCleanups.exchange(credential.token, %{
                 message
                 | results: [result]
               })

      assert {:ok, %{"commands" => [cleanup_wire]}} =
               Marshall.Compute.RelocationDestinationCleanups.exchange(credential.token, message)

      assert {:ok, cleanup} = OverallsProtocol.RelocationDestinationCleanup.command(cleanup_wire)
      assert cleanup.intent.destination.placement_id == result.placement_id
      assert cleanup.intent.destination_epoch == result.execution_epoch
      refute Map.has_key?(cleanup.intent, :stream)

      for bad <- [
            %{result | execution_epoch: cancelled.source_epoch},
            %{result | placement_id: cancelled.source_placement_id}
          ] do
        assert {:error, :invalid_outcome} =
                 Marshall.Compute.RelocationDestinationCleanups.exchange(credential.token, %{
                   message
                   | results: [bad]
                 })
      end

      assert {:error, :stale_connection} =
               Marshall.Compute.RelocationDestinationCleanups.exchange(credential.token, %{
                 message
                 | epoch: message.epoch + 1
               })

      assert {:ok, %{"commands" => [], "acknowledgements" => [_]}} =
               Marshall.Compute.RelocationDestinationCleanups.exchange(credential.token, %{
                 message
                 | results: [result]
               })

      [cleaned_destination] = Ledger.read!(Relocation, id: cancelled.id)
      assert cleaned_destination.destination_cleaned_at != nil

      assert {:ok, _} =
               Marshall.Compute.RelocationDestinationCleanups.exchange(credential.token, %{
                 message
                 | results: [result]
               })

      [duplicate_cleanup] = Ledger.read!(Relocation, id: cancelled.id)

      assert duplicate_cleanup.destination_cleaned_at ==
               cleaned_destination.destination_cleaned_at

      [confirmed] = Ledger.read!(Relocation, id: cancelled.id)
      assert confirmed.destination_revoked_at != nil and confirmed.source_revoked_at == nil

      assert {:ok, _} =
               Marshall.Compute.RelocationDestinationRevocations.exchange(credential.token, %{
                 message
                 | results: [result]
               })

      [duplicate] = Ledger.read!(Relocation, id: cancelled.id)
      assert duplicate.destination_revoked_at == confirmed.destination_revoked_at
      assert {:ok, retried} = Marshall.Compute.cancel_relocation(args, actor: c.owner)
      assert retried.cancellation_requested_at == cancelled.cancellation_requested_at
      assert {:ok, :cancelling} = RelocationCoordinator.advance(c.relocation.id)

      assert {:ok, %{"commands" => []}} = exchange(c)
      assert {:ok, %{"commands" => []}} = RelocationKeys.exchange(credential.token, message)
      assert {:ok, %{"commands" => []}} = RelocationReceives.exchange(credential.token, message)
      assert {:ok, %{"commands" => []}} = RelocationImports.exchange(credential.token, message)

      if command do
        assert {:ok, %{"commands" => [], "acknowledgements" => [_]}} =
                 exchange(c, [reply(command)])
      end

      if stage in [:receive_offered, :import_offered, :import_confirmed] do
        assert {:ok, %{"commands" => [], "acknowledgements" => [_]}} =
                 RelocationReceives.exchange(credential.token, %{message | results: [receipt]})
      end

      if stage in [:import_offered, :import_confirmed] do
        assert {:ok, %{"commands" => [], "acknowledgements" => [_]}} =
                 RelocationImports.exchange(credential.token, %{message | results: [receipt]})
      end

      assert {:ok, :cancelling} = RelocationCoordinator.advance(c.relocation.id)

      assert Enum.sort_by(holds, & &1.id) ==
               Enum.sort_by(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.id)

      for endpoint <- [:source_relocation_id, :destination_relocation_id] do
        assert [%{released_at: nil}] =
                 Ledger.read!(Marshall.Compute.TransferSlot, [{endpoint, c.relocation.id}])
      end

      assert [%{activation_operation_id: nil, committed_at: nil, finished_at: nil}] =
               Ledger.read!(Relocation, id: c.relocation.id)

      assert [current] = Ledger.read!(VirtualMachine, id: c.vm.id)
      assert current.current_placement_id == c.vm.current_placement_id

      assert current.execution_epoch == c.vm.execution_epoch and
               current.generation == c.vm.generation

      assert [] == Ledger.read!(Operation, relocation_id: c.relocation.id)
    end
  end

  @tag unprepared_key: true
  test "cancellation withdraws key preparation and a late public key cannot grant source work",
       c do
    {:ok, credential} = Credentials.rotate(c.destination.host.id, 3600)

    {:ok, session} =
      ProvisionerControl.open_execution(
        credential.token,
        %{session_id: Ash.UUID.generate(), machine_id: c.destination.host.machine_id}
      )

    message = %{session_id: session["session_id"], epoch: session["epoch"], results: []}

    assert {:ok, %{"commands" => [wire]}} =
             Marshall.Compute.RelocationKeys.exchange(credential.token, message)

    {:ok, command} = OverallsProtocol.RelocationKeys.command(wire)

    assert {:ok, _} =
             Marshall.Compute.cancel_relocation(%{relocation_id: c.relocation.id}, actor: c.owner)

    assert {:ok, %{"commands" => []}} =
             Marshall.Compute.RelocationKeys.exchange(credential.token, message)

    result =
      command
      |> Map.take([:id, :placement_id, :execution_epoch])
      |> Map.put(:public_key, transfer_endpoint()["host_key"])

    assert {:ok, %{"commands" => [], "acknowledgements" => [_]}} =
             Marshall.Compute.RelocationKeys.exchange(credential.token, %{
               message
               | results: [result]
             })

    assert {:ok, %{"commands" => []}} = exchange(c)
    assert [] == Ledger.read!(SourcePermitRequest, relocation_id: c.relocation.id)
    assert {:ok, :cancelling} = Marshall.Compute.RelocationCoordinator.advance(c.relocation.id)
  end

  for {phase, stopped} <- [running: false, stopped: true, stopping: false] do
    @tag initially_stopped: stopped
    @tag stop_pending: phase == :stopping
    test "cancelled #{phase} source restores its original state under fresh fenced authority",
         c do
      alias Marshall.Compute.{Relocation, RelocationCoordinator, RelocationRevocations}
      holds = Ledger.read!(Reservation, vm_id: c.vm.id)

      assert {:ok, _} =
               Marshall.Compute.cancel_relocation(%{relocation_id: c.relocation.id},
                 actor: c.owner
               )

      message = %{session_id: c.session["session_id"], epoch: c.session["epoch"], results: []}
      assert {:ok, :cancelling} = RelocationCoordinator.advance(c.relocation.id)

      assert {:ok, %{"commands" => []}} =
               Marshall.Compute.RelocationSnapshotCleanups.exchange(c.token, message)

      assert Enum.all?(
               Ledger.read!(Operation, relocation_id: c.relocation.id),
               &(&1.execution_epoch == c.vm.execution_epoch)
             )

      {:ok, %{"commands" => [wire]}} = RelocationRevocations.exchange(c.token, message)
      {:ok, revoke} = OverallsProtocol.RelocationRevocation.command(wire)
      receipt = Map.take(revoke, [:id, :placement_id, :execution_epoch])
      assert {:ok, _} = RelocationRevocations.exchange(c.token, %{message | results: [receipt]})
      assert {:ok, :restoring_source} = RelocationCoordinator.advance(c.relocation.id)
      assert {:ok, :restoring_source} = RelocationCoordinator.advance(c.relocation.id)

      quiesce_kind = if c.relocation.preserves_memory, do: :pause, else: :stop
      quiesce_state = if c.relocation.preserves_memory, do: :paused, else: :stopped

      assert [%{kind: ^quiesce_kind} = stop] =
               Ledger.read!(Operation, relocation_id: c.relocation.id, status: :pending)

      assert stop.placement_id == c.vm.current_placement_id and
               stop.execution_epoch == c.vm.execution_epoch + 1

      assert stop.generation == c.vm.generation + 1

      if c.relocation.source_stop_operation_id do
        assert [%{status: :cancelled}] =
                 Ledger.read!(Operation, id: c.relocation.source_stop_operation_id)
      end

      execution = Map.merge(message, %{report: nil, outcomes: [], acknowledgements: []})

      assert {:ok, %{"commands" => [stop_wire]}} =
               ProvisionerControl.exchange_execution(c.token, execution)

      assert {:ok, delivered} = OverallsProtocol.Execution.command(stop_wire)
      assert delivered.id == stop.id

      uncertain = %{
        id: Ash.UUID.generate(),
        vm_id: c.vm.id,
        placement_id: stop.placement_id,
        execution_epoch: stop.execution_epoch,
        generation: stop.generation,
        operation_id: stop.id,
        sequence: c.vm.outcome_sequence + 1,
        state: :unknown,
        compute_empty: false,
        disk_present: true,
        cleanup_complete: false,
        reason: :cleanup_failed
      }

      assert {:ok, _} =
               ProvisionerControl.exchange_execution(c.token, %{execution | outcomes: [uncertain]})

      assert {:ok, :restoring_source} = RelocationCoordinator.advance(c.relocation.id)

      assert [%{kind: ^quiesce_kind}] =
               Ledger.read!(Operation, relocation_id: c.relocation.id, status: :pending)

      stopped = %{
        uncertain
        | id: Ash.UUID.generate(),
          sequence: c.vm.outcome_sequence + 2,
          state: quiesce_state,
          compute_empty: true,
          reason: :none
      }

      stopped =
        if stop.kind == :pause, do: Map.put(stopped, :checkpoint, checkpoint(c.vm)), else: stopped

      assert {:ok, _} =
               ProvisionerControl.exchange_execution(c.token, %{execution | outcomes: [stopped]})

      later_unknown = %{uncertain | id: Ash.UUID.generate(), sequence: stopped.sequence + 1}

      assert {:ok, _} =
               ProvisionerControl.exchange_execution(c.token, %{
                 execution
                 | outcomes: [later_unknown]
               })

      assert {:ok, :restoring_source} = RelocationCoordinator.advance(c.relocation.id)
      assert [] == Ledger.read!(Operation, relocation_id: c.relocation.id, kind: :start)
      stopped = %{stopped | id: Ash.UUID.generate(), sequence: stopped.sequence + 2}

      assert {:ok, _} =
               ProvisionerControl.exchange_execution(c.token, %{execution | outcomes: [stopped]})

      if c.relocation.original_state == :running do
        refresh_restoration_capacity!(c)
        assert {:ok, :restoring_source} = RelocationCoordinator.advance(c.relocation.id)
        assert {:ok, :restoring_source} = RelocationCoordinator.advance(c.relocation.id)
        assert [start] = Ledger.read!(Operation, relocation_id: c.relocation.id, kind: :resume)

        assert start.command_snapshot["checkpoint"] ==
                 OverallsProtocol.Checkpoint.encode(stopped.checkpoint)

        assert start.execution_epoch == stop.execution_epoch and
                 start.generation == stop.generation + 1

        assert {:ok, %{"commands" => [_]}} =
                 ProvisionerControl.exchange_execution(c.token, execution)

        running = %{
          stopped
          | id: Ash.UUID.generate(),
            operation_id: start.id,
            generation: start.generation,
            sequence: stopped.sequence + 1,
            state: :running,
            compute_empty: false
        }

        assert {:ok, _} =
                 ProvisionerControl.exchange_execution(c.token, %{execution | outcomes: [running]})

        unknown_start =
          running
          |> Map.merge(%{
            id: Ash.UUID.generate(),
            sequence: running.sequence + 1,
            state: :unknown,
            reason: :cleanup_failed
          })
          |> Map.delete(:checkpoint)

        assert {:ok, _} =
                 ProvisionerControl.exchange_execution(c.token, %{
                   execution
                   | outcomes: [unknown_start]
                 })

        assert {:ok, :restoring_source} = RelocationCoordinator.advance(c.relocation.id)
        running = %{running | id: Ash.UUID.generate(), sequence: running.sequence + 2}

        assert {:ok, _} =
                 ProvisionerControl.exchange_execution(c.token, %{execution | outcomes: [running]})
      end

      assert {:ok, :source_restored_pending_cleanup} =
               RelocationCoordinator.advance(c.relocation.id)

      [restored] = Ledger.read!(Relocation, id: c.relocation.id)

      assert restored.source_restored_at != nil and restored.finished_at == nil and
               restored.committed_at == nil

      assert restored.activation_operation_id == nil

      # Restoration can proceed without a fresh inventory; ordinary Start still
      # requires the host's current execution/image report.
      Ledger.update!(c.source.host, :report, %{
        reported_at: Ledger.now(),
        inventory: c.source.report.inventory
      })

      cycle_lifecycle(c, c.token, message)

      # Explicit Stop discards only the authoritative source checkpoint. The
      # destination's retained copy remains charged until its cleanup receipt.
      expected_holds =
        Enum.map(holds, fn hold ->
          if hold.placement_id == restored.source_placement_id,
            do: %{hold | checkpoint_bytes: 0},
            else: hold
        end)

      holds = Ledger.read!(Reservation, vm_id: c.vm.id)
      assert Enum.sort_by(holds, & &1.id) == Enum.sort_by(expected_holds, & &1.id)

      cleanup_result = %{
        id: restored.id,
        placement_id: restored.source_placement_id,
        execution_epoch: restored.source_epoch
      }

      assert {:error, :invalid_outcome} =
               Marshall.Compute.RelocationSnapshotCleanups.exchange(c.token, %{
                 message
                 | results: [cleanup_result]
               })

      assert {:ok, %{"commands" => [cleanup_wire]}} =
               Marshall.Compute.RelocationSnapshotCleanups.exchange(c.token, message)

      assert {:ok, cleanup} = OverallsProtocol.RelocationSnapshotCleanup.command(cleanup_wire)
      assert Map.take(cleanup, [:id, :placement_id, :execution_epoch]) == cleanup_result

      for bad <- [
            %{cleanup_result | placement_id: restored.destination_placement_id},
            %{cleanup_result | execution_epoch: restored.destination_epoch}
          ] do
        assert {:error, :invalid_outcome} =
                 Marshall.Compute.RelocationSnapshotCleanups.exchange(c.token, %{
                   message
                   | results: [bad]
                 })
      end

      assert {:error, :stale_connection} =
               Marshall.Compute.RelocationSnapshotCleanups.exchange(c.token, %{
                 message
                 | epoch: message.epoch + 1
               })

      assert {:ok, %{"commands" => [], "acknowledgements" => [id]}} =
               Marshall.Compute.RelocationSnapshotCleanups.exchange(c.token, %{
                 message
                 | results: [cleanup_result]
               })

      assert id == restored.id
      [cleaned] = Ledger.read!(Relocation, id: restored.id)
      assert cleaned.source_snapshots_cleaned_at != nil

      assert {:ok, _} =
               Marshall.Compute.RelocationSnapshotCleanups.exchange(c.token, %{
                 message
                 | results: [cleanup_result]
               })

      [duplicate] = Ledger.read!(Relocation, id: restored.id)
      assert duplicate.source_snapshots_cleaned_at == cleaned.source_snapshots_cleaned_at
      assert duplicate.finished_at == nil

      assert Enum.sort_by(holds, & &1.id) ==
               Enum.sort_by(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.id)

      assert {:ok, :source_restored_pending_cleanup} =
               RelocationCoordinator.advance(c.relocation.id)

      # No relocation holds temporary headroom, so snapshot cleanup frees nothing.
      assert Enum.all?(holds, &(&1.temporary_disk_bytes == 0))

      assert Enum.sort_by(holds, & &1.id) ==
               Enum.sort_by(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.id)

      [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
      assert vm.current_placement_id == c.vm.current_placement_id
      assert vm.execution_epoch == c.vm.execution_epoch + 1

      assert vm.desired_state == c.relocation.original_state and
               vm.observed_state == c.relocation.original_state

      {:ok, destination_credential} = Credentials.rotate(c.destination.host.id, 3600)

      {:ok, destination_session} =
        ProvisionerControl.open_execution(destination_credential.token, %{
          session_id: Ash.UUID.generate(),
          machine_id: c.destination.host.machine_id
        })

      destination_message = %{
        session_id: destination_session["session_id"],
        epoch: destination_session["epoch"],
        results: []
      }

      destination_result = %{
        id: restored.id,
        placement_id: restored.destination_placement_id,
        execution_epoch: restored.destination_epoch
      }

      for exchange <- [
            Marshall.Compute.RelocationDestinationCleanups,
            Marshall.Compute.RelocationDestinationRevocations
          ] do
        assert {:ok, %{"commands" => [_]}} =
                 exchange.exchange(destination_credential.token, destination_message)

        assert {:ok, _} =
                 exchange.exchange(destination_credential.token, %{
                   destination_message
                   | results: [destination_result]
                 })
      end

      assert {:ok, :cancelled} = RelocationCoordinator.advance(restored.id)
      [finished] = Ledger.read!(Relocation, id: restored.id)
      assert finished.finished_at != nil and finished.committed_at == nil
      assert {:ok, :finished} = RelocationCoordinator.advance(restored.id)
      assert [^finished] = Ledger.read!(Relocation, id: restored.id)
      [source_hold] = Ledger.read!(Reservation, placement_id: restored.source_placement_id)
      [target_hold] = Ledger.read!(Reservation, placement_id: restored.destination_placement_id)
      assert source_hold.disk_held and source_hold.temporary_disk_bytes == 0
      assert source_hold.compute_held == (restored.original_state == :running)
      refute target_hold.disk_held or target_hold.compute_held
      assert target_hold.temporary_disk_bytes == 0

      assert Enum.all?(
               Ledger.read!(Marshall.Compute.TransferSlot, source_relocation_id: restored.id),
               & &1.released_at
             )

      assert Enum.all?(
               Ledger.read!(Marshall.Compute.TransferSlot,
                 destination_relocation_id: restored.id
               ),
               & &1.released_at
             )

      # Retained old-epoch source observations must never overwrite restored authority.
      [original] =
        Ledger.read!(Operation,
          vm_id: c.vm.id,
          generation: c.vm.generation,
          execution_epoch: c.vm.execution_epoch
        )

      old = %{
        stopped
        | id: Ash.UUID.generate(),
          operation_id: original.id,
          execution_epoch: original.execution_epoch,
          generation: original.generation,
          sequence: 100,
          state:
            case original.kind do
              kind when kind in [:provision, :start, :resume] -> :running
              :pause -> :paused
              :stop -> :stopped
            end,
          compute_empty: original.kind in [:stop, :pause]
      }

      old =
        if original.kind == :pause,
          do: Map.put(old, :checkpoint, checkpoint(c.vm)),
          else: Map.delete(old, :checkpoint)

      assert {:ok, _} =
               ProvisionerControl.exchange_execution(c.token, %{execution | outcomes: [old]})

      assert [^vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] cancellation-failed-resume-is-not-replayed
  # A consumed cancellation resume MUST NOT create a second resume or cold start
  # after unknown/failed outcomes, even when an old retry window expires. Both
  # source and destination storage commitments remain until physical cleanup.
  test "failed cancellation resume retains memory authority without replay or cold boot", c do
    alias Marshall.Compute.{Relocation, RelocationCoordinator, RelocationRevocations}

    {:ok, _} =
      Marshall.Compute.cancel_relocation(%{relocation_id: c.relocation.id}, actor: c.owner)

    message = %{session_id: c.session["session_id"], epoch: c.session["epoch"], results: []}
    {:ok, %{"commands" => [wire]}} = RelocationRevocations.exchange(c.token, message)
    {:ok, revoke} = OverallsProtocol.RelocationRevocation.command(wire)

    {:ok, _} =
      RelocationRevocations.exchange(
        c.token,
        %{message | results: [Map.take(revoke, [:id, :placement_id, :execution_epoch])]}
      )

    holds = Enum.sort_by(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.id)
    assert {:ok, :restoring_source} = RelocationCoordinator.advance(c.relocation.id)
    [relocation] = Ledger.read!(Relocation, id: c.relocation.id)
    [pause] = Ledger.read!(Operation, id: relocation.cancellation_stop_operation_id)
    assert pause.kind == :pause
    restoration_outcome(c, pause, :unknown)
    assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)
    assert [%{cancellation_start_operation_id: nil}] = Ledger.read!(Relocation, id: relocation.id)
    restoration_outcome(c, pause, :paused)
    assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)
    [relocation] = Ledger.read!(Relocation, id: relocation.id)
    [resume] = Ledger.read!(Operation, id: relocation.cancellation_start_operation_id)
    assert resume.kind == :resume and resume.generation == pause.generation + 1

    for state <- [:unknown, :failed] do
      restoration_outcome(c, resume, state)

      for _ <- 1..3,
          do: assert({:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id))

      assert [resume.id] ==
               Enum.map(
                 Ledger.read!(Operation, relocation_id: relocation.id, kind: :resume),
                 & &1.id
               )

      assert Ledger.read!(Operation, relocation_id: relocation.id, kind: :start) == []
    end

    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

    Ledger.intent!(vm, %{crash_restart_times: List.duplicate(DateTime.add(Ledger.now(), -601), 3)})

    assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)
    [retained] = Ledger.read!(Relocation, id: relocation.id)
    assert retained.source_restored_at == nil and retained.finished_at == nil
    assert retained.cancellation_start_operation_id == resume.id
    assert holds == Enum.sort_by(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.id)
  end

  @spec restoration_outcome(
          map(),
          Operation.t(),
          :unknown | :paused | :stopped | :running | :failed
        ) :: map()
  defp restoration_outcome(c, operation, state),
    do: restoration_outcome(c, operation, state, true)

  @spec restoration_outcome(
          map(),
          Operation.t(),
          :unknown | :paused | :stopped | :running | :failed,
          boolean()
        ) :: map()
  defp restoration_outcome(c, operation, state, disk_present) do
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
      compute_empty: state in [:stopped, :paused, :failed],
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
      case {operation.kind, state} do
        {:pause, :paused} ->
          Map.put(outcome, :checkpoint, checkpoint(vm))

        {:resume, :running} ->
          {:ok, descriptor} =
            OverallsProtocol.Checkpoint.decode(operation.command_snapshot["checkpoint"])

          Map.put(outcome, :checkpoint, descriptor)

        _ ->
          outcome
      end

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

    if state == :paused, do: refresh_restoration_capacity!(c)
    outcome
  end

  # Positive restore witnesses assume healthy capacity throughout their long
  # receipt history; refresh only sandbox report times, never physical budgets.
  @spec refresh_restoration_capacity!(%{vm: VirtualMachine.t()}) :: :ok
  defp refresh_restoration_capacity!(c) do
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

    {:ok, :ok} =
      Ledger.transaction(fn ->
        host = Ledger.lock!(Host, vm.host_id)
        vm = Ledger.lock!(VirtualMachine, vm.id)
        [reservation] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
        [pool] = Ledger.read!(Marshall.Compute.StoragePool, id: reservation.pool_id)
        Ledger.update!(host, :report, %{reported_at: Ledger.now()})
        Ledger.update!(pool, :report, %{reported_at: Ledger.now()})
        :ok
      end)

    :ok
  end

  test "source revocation receipts require an offered cancelled source identity", c do
    alias Marshall.Compute.{Relocation, RelocationRevocations}
    message = %{session_id: c.session["session_id"], epoch: c.session["epoch"], results: []}

    result = %{
      id: c.relocation.id,
      placement_id: c.relocation.source_placement_id,
      execution_epoch: c.relocation.source_epoch
    }

    assert {:ok, %{"commands" => []}} = RelocationRevocations.exchange(c.token, message)

    assert {:error, :invalid_outcome} =
             RelocationRevocations.exchange(c.token, %{message | results: [result]})

    assert {:ok, _} =
             Marshall.Compute.cancel_relocation(%{relocation_id: c.relocation.id}, actor: c.owner)

    holds = Ledger.read!(Reservation, vm_id: c.vm.id)

    assert {:error, :invalid_outcome} =
             RelocationRevocations.exchange(c.token, %{message | results: [result]})

    assert {:ok, %{"commands" => [wire]}} = RelocationRevocations.exchange(c.token, message)
    assert {:ok, command} = OverallsProtocol.RelocationRevocation.command(wire)
    assert Map.take(command, [:id, :placement_id, :execution_epoch]) == result
    assert command.host_id == c.source.host.id

    for wrong <- [
          %{result | placement_id: c.relocation.destination_placement_id},
          %{result | execution_epoch: result.execution_epoch + 1}
        ] do
      assert {:error, :invalid_outcome} =
               RelocationRevocations.exchange(c.token, %{message | results: [wrong]})
    end

    assert {:error, :invalid_outcome} =
             RelocationRevocations.exchange(c.token, %{
               message
               | results: [result, %{result | id: Ash.UUID.generate()}]
             })

    assert [%{source_revoked_at: nil}] = Ledger.read!(Relocation, id: result.id)

    assert {:error, :stale_connection} =
             RelocationRevocations.exchange(c.token, %{
               message
               | epoch: message.epoch + 1,
                 results: [result]
             })

    assert {:ok, %{"commands" => [], "acknowledgements" => [_]}} =
             RelocationRevocations.exchange(c.token, %{message | results: [result]})

    [confirmed] = Ledger.read!(Relocation, id: result.id)
    assert confirmed.source_revoked_at != nil
    assert {:ok, _} = RelocationRevocations.exchange(c.token, %{message | results: [result]})
    assert [retried] = Ledger.read!(Relocation, id: result.id)
    assert retried.source_revoked_at == confirmed.source_revoked_at

    assert Enum.sort_by(holds, & &1.id) ==
             Enum.sort_by(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.id)

    assert {:ok, :restoring_source} = Marshall.Compute.RelocationCoordinator.advance(result.id)
  end

  test "cancellation uses current manager permission even on an idempotent retry", c do
    manager = user()

    grant = fn role ->
      Marshall.Access.set_access(
        %{
          vm_id: c.vm.id,
          email: to_string(manager.email),
          role: role,
          idempotency_key: Ash.UUID.generate()
        },
        actor: c.owner
      )
    end

    args = %{relocation_id: c.relocation.id}
    assert {:ok, _} = grant.(:operator)
    assert {:error, _} = Marshall.Compute.cancel_relocation(args, actor: manager)
    assert {:ok, _} = grant.(:manager)
    assert {:ok, cancelled} = Marshall.Compute.cancel_relocation(args, actor: manager)
    assert cancelled.cancellation_requested_by_id == manager.id
    assert {:ok, _} = grant.(:revoked)
    assert {:error, _} = Marshall.Compute.cancel_relocation(args, actor: manager)
    assert {:ok, repeated} = Marshall.Compute.cancel_relocation(args, actor: c.owner)
    assert repeated.cancellation_requested_by_id == manager.id
    assert repeated.cancellation_requested_at == cancelled.cancellation_requested_at
  end

  test "cancelling a running move before its stop preserves execution and never snapshotted",
       c do
    # ADR-0197: no source request exists for a running source before its recorded pause.
    assert {:ok, %{"commands" => []}} = exchange(c)
    assert [] == Ledger.read!(SourcePermitRequest, relocation_id: c.relocation.id)

    assert {:ok, _} =
             Marshall.Compute.cancel_relocation(%{relocation_id: c.relocation.id}, actor: c.owner)

    assert {:ok, %{"commands" => []}} = exchange(c)
    assert {:ok, :cancelling} = Marshall.Compute.RelocationCoordinator.advance(c.relocation.id)
    assert [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    assert vm.desired_state == :running and vm.generation == c.vm.generation
    assert [] == Ledger.read!(Operation, relocation_id: c.relocation.id)
  end

  @tag initially_stopped: true
  test "full requests and jobs are durable while key receipts and replies cannot move authority",
       c do
    before = Ledger.now() |> DateTime.to_unix()
    assert {:ok, %{"commands" => [wire], "acknowledgements" => []}} = exchange(c)
    {:ok, command} = Wire.command(wire)
    assert command.intent.source.placement_id == c.vm.current_placement_id
    assert command.intent.destination.placement_id == c.relocation.destination_placement_id
    assert command.generation == c.vm.generation
    assert command.expires_at in (before + 180)..(DateTime.to_unix(Ledger.now()) + 180)

    assert [%{args: %{"primary_key" => %{"id" => id}}}] =
             Oban.Testing.all_enqueued(
               repo: Marshall.Repo,
               worker: Marshall.Compute.Workers.NotifySourcePermit
             )

    assert id == command.id
    assert {:ok, %{"commands" => [^wire]}} = exchange(c)
    result = reply(command)
    unknown = %{result | id: "ffffffff-ffff-4fff-8fff-ffffffffffff"}
    assert {:error, :invalid_outcome} = exchange(c, [result, unknown])
    assert [%{descriptor: nil}] = Ledger.read!(SourcePermitRequest, id: command.id)
    assert {:ok, %{"commands" => [], "acknowledgements" => [^id]}} = exchange(c, [result])
    assert {:ok, %{"acknowledgements" => [^id]}} = exchange(c, [result])

    assert {:error, :outcome_conflict} =
             exchange(c, [put_in(result.descriptor.stream.to_guid, "201")])

    assert [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

    assert vm.execution_epoch == c.vm.execution_epoch and
             vm.current_placement_id == c.vm.current_placement_id

    assert Enum.all?(Ledger.read!(Reservation, vm_id: vm.id), & &1.disk_held)
  end

  @tag initially_stopped: true
  test "an originally stopped workload receives full requests without compute or temporary holds",
       c do
    holds = Ledger.read!(Reservation, vm_id: c.vm.id)

    assert Enum.all?(
             holds,
             &(&1.disk_held and not &1.compute_held and &1.temporary_disk_bytes == 0)
           )

    assert {:ok, %{"commands" => [wire]}} = exchange(c)
    assert {:ok, command} = Wire.command(wire)
    assert command.generation == c.vm.generation
    assert {:ok, %{"commands" => [^wire]}} = exchange(c)
    assert {:ok, %{"commands" => []}} = exchange(c, [reply(command)])
    {:ok, credential} = Credentials.rotate(c.destination.host.id, 3600)

    {:ok, session} =
      ProvisionerControl.open_execution(
        credential.token,
        %{session_id: Ash.UUID.generate(), machine_id: c.destination.host.machine_id}
      )

    message = %{session_id: session["session_id"], epoch: session["epoch"], results: []}

    assert {:ok, %{"commands" => [%{"descriptor" => %{"stream" => %{"to_guid" => _}}}]}} =
             RelocationReceives.exchange(credential.token, message)

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    receive_logs =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :relocation_id, :vm_id]], fn ->
        assert {:ok, _} =
                 RelocationReceives.exchange(
                   credential.token,
                   %{message | results: [Map.put(reply(command), :dataset_guid, "300")]}
                 )
      end)

    assert receive_logs =~ "Relocation receive receipt recorded"
    assert receive_logs =~ "event=relocation.receive_recorded"
    assert receive_logs =~ c.relocation.id
    assert receive_logs =~ c.vm.id

    replay_logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} =
                 RelocationReceives.exchange(
                   credential.token,
                   %{message | results: [Map.put(reply(command), :dataset_guid, "300")]}
                 )
      end)

    refute replay_logs =~ "event=relocation.receive_recorded"

    assert Enum.sort_by(holds, & &1.id) ==
             Enum.sort_by(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.id)

    assert [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    assert vm.desired_state == :stopped and vm.observed_state == :stopped
    assert vm.current_placement_id == c.vm.current_placement_id

    assert {:ok, %{"commands" => [_]}} =
             Marshall.Compute.RelocationImports.exchange(credential.token, message)

    assert {:ok, _} =
             Marshall.Compute.RelocationImports.exchange(
               credential.token,
               %{message | results: [Map.put(reply(command), :dataset_guid, "300")]}
             )

    Ledger.update!(c.destination.host, :report, %{reported_at: Ledger.now()})
    assert {:ok, :committed} = Marshall.Compute.RelocationCoordinator.advance(c.relocation.id)

    assert {:error, rejected} =
             Marshall.Compute.cancel_relocation(%{relocation_id: c.relocation.id}, actor: c.owner)

    assert Exception.message(rejected) =~ "relocation_committed"
    [committed] = Ledger.read!(Marshall.Compute.Relocation, id: c.relocation.id)
    [activation] = Ledger.read!(Operation, id: committed.activation_operation_id)
    assert activation.kind == :stop
    release_committed_streams(c, credential.token, message)
    assert [current] = Ledger.read!(VirtualMachine, id: vm.id)
    assert current.desired_state == :stopped
    assert current.current_placement_id == c.relocation.destination_placement_id

    assert Enum.all?(
             Ledger.read!(Reservation, vm_id: vm.id),
             &(&1.disk_held and not &1.compute_held)
           )

    event = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      placement_id: activation.placement_id,
      operation_id: activation.id,
      execution_epoch: activation.execution_epoch,
      generation: activation.generation,
      sequence: 1,
      state: :stopped,
      compute_empty: true,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    assert {:ok, _} =
             Ledger.transaction(fn ->
               Ledger.lock!(Host, c.destination.host.id)
               Marshall.Compute.Outcomes.ingest_locked!(c.destination.host.id, [event])
             end)

    assert {:ok, %{"commands" => []}} =
             Marshall.Compute.RelocationReadiness.exchange(credential.token, message)

    assert [%{status: :ready, requires_boot: false, boot_id: nil}] =
             Ledger.read!(Marshall.Compute.ReadinessRequest, id: activation.id)

    assert {:ok, %{relocation: %{downtime: nil}}} =
             Marshall.Compute.get_vm(%{vm_id: c.vm.id}, actor: c.owner)

    cleanup_flow(c, credential.token, message)
  end

  @tag initially_stopped: true
  test "handoff commit diagnostics carry every correlation key", c do
    assert {:ok, %{"commands" => [wire]}} = exchange(c)
    {:ok, command} = Wire.command(wire)
    assert {:ok, _} = exchange(c, [reply(command)])
    {:ok, credential} = Credentials.rotate(c.destination.host.id, 3600)

    {:ok, session} =
      ProvisionerControl.open_execution(
        credential.token,
        %{session_id: Ash.UUID.generate(), machine_id: c.destination.host.machine_id}
      )

    message = %{session_id: session["session_id"], epoch: session["epoch"], results: []}
    imported = Map.put(reply(command), :dataset_guid, "300")

    assert {:ok, %{"commands" => [_]}} =
             Marshall.Compute.RelocationReceives.exchange(credential.token, message)

    assert {:ok, _} =
             Marshall.Compute.RelocationReceives.exchange(
               credential.token,
               %{message | results: [imported]}
             )

    assert {:ok, %{"commands" => [_]}} =
             Marshall.Compute.RelocationImports.exchange(credential.token, message)

    assert {:ok, _} =
             Marshall.Compute.RelocationImports.exchange(
               credential.token,
               %{message | results: [imported]}
             )

    Ledger.update!(c.destination.host, :report, %{reported_at: Ledger.now()})
    [before] = Ledger.read!(VirtualMachine, id: c.vm.id)

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      ExUnit.CaptureLog.capture_log(
        [
          metadata: [
            :event,
            :relocation_id,
            :vm_id,
            :host_id,
            :placement_id,
            :execution_epoch,
            :generation
          ]
        ],
        fn ->
          assert {:ok, :committed} =
                   Marshall.Compute.RelocationCoordinator.advance(c.relocation.id)
        end
      )

    assert logs =~ "Relocation placement handoff committed"
    assert logs =~ "event=relocation.handoff_committed"
    assert logs =~ "relocation_id=" <> c.relocation.id
    assert logs =~ "vm_id=" <> c.vm.id
    assert logs =~ "host_id=" <> c.relocation.destination_host_id
    assert logs =~ "placement_id=" <> c.relocation.destination_placement_id

    assert logs =~ "execution_epoch=" <> Integer.to_string(c.relocation.destination_epoch)

    assert logs =~ "generation=" <> Integer.to_string(before.generation + 1)
  end

  @tag initially_stopped: true
  test "stopped transfer still requires both disk commitments", c do
    [destination] = Ledger.read!(Reservation, placement_id: c.relocation.destination_placement_id)
    Ledger.update!(destination, :release_all, %{})
    assert {:ok, %{"commands" => []}} = exchange(c)
    assert [] == Ledger.read!(SourcePermitRequest, relocation_id: c.relocation.id)
  end

  @tag initially_stopped: true
  test "renewal creates new expiry/revision and accepts a delayed result only against retained history",
       c do
    {:ok, %{"commands" => [wire]}} = exchange(c)
    {:ok, original} = Wire.command(wire)

    old = %{
      original
      | id: Ash.UUID.generate(),
        revision: 2,
        expires_at: DateTime.to_unix(Ledger.now()) - 1
    }

    Ledger.create!(SourcePermitRequest, :enqueue, %{
      id: old.id,
      relocation_id: c.relocation.id,
      source_host_id: c.source.host.id,
      revision: 2,
      request: Wire.encode_command(old)
    })

    assert {:ok, %{"commands" => [renewed]}} = exchange(c, [reply(old)])
    {:ok, renewed} = Wire.command(renewed)
    assert renewed.revision == 3 and renewed.id != old.id
    assert renewed.to_guid == "200" and renewed.expires_at > old.expires_at
    assert {:ok, _} = exchange(c, [reply(original)])

    assert {:error, :outcome_conflict} =
             exchange(c, [put_in(reply(original).descriptor.stream.to_guid, "201")])

    assert {:error, :invalid_outcome} =
             exchange(c, [put_in(reply(renewed).descriptor.stream.to_guid, "201")])

    assert length(Ledger.read!(SourcePermitRequest, relocation_id: c.relocation.id)) == 3
  end

  @tag initially_stopped: true
  test "changed source intent, foreign hosts and old sessions cannot grant work", c do
    {:ok, %{"commands" => [wire]}} = exchange(c)
    {:ok, command} = Wire.command(wire)
    {:ok, other} = Credentials.rotate(c.destination.host.id, 3600)

    {:ok, session} =
      ProvisionerControl.open_execution(
        other.token,
        %{session_id: Ash.UUID.generate(), machine_id: c.destination.host.machine_id}
      )

    assert {:error, :invalid_outcome} =
             exchange(%{c | token: other.token, session: session}, [reply(command)])

    Ledger.intent!(c.vm, %{
      generation: c.vm.generation + 1,
      desired_state: :stopped
    })

    assert {:ok, %{"commands" => []}} = exchange(c)

    {:ok, _} =
      ProvisionerControl.open_execution(
        c.token,
        %{session_id: Ash.UUID.generate(), machine_id: c.source.host.machine_id}
      )

    assert {:error, :stale_connection} = exchange(c, [reply(command)])
    assert {:ok, :ok} = Credentials.revoke(c.source.host.id)
    assert {:error, :unauthorized} = exchange(c)
  end

  defp exchange(c, results \\ []) do
    {:ok, message} =
      Wire.exchange(%{
        "version" => 4,
        "session_id" => c.session["session_id"],
        "epoch" => c.session["epoch"],
        "results" => Enum.map(results, &Wire.encode_result/1)
      })

    RelocationSources.exchange(c.token, message)
  end

  @tag initially_stopped: true
  test "destination receipt batches roll back and source lease expiry suppresses receive commands",
       c do
    {:ok, credential} = Credentials.rotate(c.destination.host.id, 3600)

    {:ok, session} =
      ProvisionerControl.open_execution(
        credential.token,
        %{session_id: Ash.UUID.generate(), machine_id: c.destination.host.machine_id}
      )

    receive_exchange = fn results ->
      RelocationReceives.exchange(
        credential.token,
        %{session_id: session["session_id"], epoch: session["epoch"], results: results}
      )
    end

    assert {:ok, %{"commands" => []}} = receive_exchange.([])
    {:ok, %{"commands" => [wire]}} = exchange(c)
    {:ok, command} = Wire.command(wire)
    assert {:ok, %{"commands" => []}} = receive_exchange.([])
    assert {:ok, _} = exchange(c, [reply(command)])
    assert {:ok, %{"commands" => [%{"id" => id}]}} = receive_exchange.([])
    assert id == command.id
    receipt = Map.put(reply(command), :dataset_guid, "300")

    assert {:error, :invalid_outcome} =
             receive_exchange.([receipt, %{receipt | id: Ash.UUID.generate()}])

    assert [%{destination_dataset_guid: nil}] = Ledger.read!(SourcePermitRequest, id: id)

    assert {:error, :invalid_outcome} =
             receive_exchange.([put_in(receipt.descriptor.stream.to_guid, "201")])

    # A separate immutable expired revision models retained history without
    # changing published lease fields or mocking the database clock.
    expired = %{
      command
      | id: Ash.UUID.generate(),
        revision: 2,
        expires_at: DateTime.to_unix(Ledger.now()) - 1
    }

    expired_record =
      Ledger.create!(SourcePermitRequest, :enqueue, %{
        id: expired.id,
        relocation_id: c.relocation.id,
        source_host_id: c.source.host.id,
        revision: 2,
        request: Wire.encode_command(expired)
      })

    Ledger.update!(expired_record, :record_result, %{
      descriptor: OverallsProtocol.Relocation.encode_descriptor(receipt.descriptor)
    })

    assert {:ok, %{"commands" => []}} = receive_exchange.([])
    assert {:ok, %{"acknowledgements" => [^id]}} = receive_exchange.([receipt])

    assert {:error, :outcome_conflict} =
             receive_exchange.([%{receipt | id: expired.id, dataset_guid: "301"}])

    assert {:ok, _} = receive_exchange.([%{receipt | id: expired.id}])

    assert Enum.all?(
             Ledger.read!(Reservation, vm_id: c.vm.id),
             & &1.disk_held
           )
  end

  for readiness_mode <- [:ready, :timeout, :cleanup_delete, :retry, :retry_delete] do
    @tag readiness_mode: readiness_mode
    test "probe, physical stop, full copy, import and readiness #{readiness_mode}", c do
      alias Marshall.Compute.{Relocation, RelocationCoordinator}
      holds = Ledger.read!(Reservation, vm_id: c.vm.id)
      assert {:ok, :waiting} = RelocationCoordinator.advance(c.relocation.id)
      # Nothing is copied while the source runs (ADR-0197).
      assert {:ok, %{"commands" => []}} = exchange(c)
      assert {:ok, :waiting} = RelocationCoordinator.advance(c.relocation.id)

      {:ok, credential} = Credentials.rotate(c.destination.host.id, 3600)

      {:ok, session} =
        ProvisionerControl.open_execution(credential.token, %{
          session_id: Ash.UUID.generate(),
          machine_id: c.destination.host.machine_id
        })

      receive = fn results ->
        RelocationReceives.exchange(credential.token, %{
          session_id: session["session_id"],
          epoch: session["epoch"],
          results: results
        })
      end

      assert {:ok, %{"commands" => []}} = receive.([])
      assert {:ok, :waiting} = RelocationCoordinator.advance(c.relocation.id)
      probe = Marshall.RelocationProbeFixture.applied!(c.relocation, c.vm)

      for host <- [c.source.host, c.destination.host] do
        Ledger.update!(host, :report, %{reported_at: Ledger.now()})
      end

      Ledger.update!(c.destination.host, :report, %{
        inventory: Map.put(c.destination.report.inventory, "images", [])
      })

      assert {:ok, :stopping} = RelocationCoordinator.advance(c.relocation.id)
      assert {:ok, :stopping} = RelocationCoordinator.advance(c.relocation.id)
      [relocation] = Ledger.read!(Relocation, id: c.relocation.id)

      assert relocation.source_preflight_request_id == probe.id and
               relocation.phase == :stopping_source

      [operation] = Ledger.read!(Operation, id: relocation.source_stop_operation_id)
      [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
      assert vm.generation == c.vm.generation + 1
      assert vm.current_placement_id == c.vm.current_placement_id
      assert vm.execution_epoch == c.vm.execution_epoch
      assert operation.initiator == :relocation and operation.kind == :pause
      assert operation.relocation_id == relocation.id

      assert Enum.sort_by(holds, & &1.id) ==
               Enum.sort_by(Ledger.read!(Reservation, vm_id: vm.id), & &1.id)

      refute RelocationCoordinator.stop_confirmed?(relocation, vm)

      assert {:ok, %{relocation: %{downtime: nil}}} =
               Marshall.Compute.get_vm(%{vm_id: vm.id}, actor: c.owner)

      assert {:ok, %{"commands" => []}} = exchange(c)

      event = %{
        id: Ash.UUID.generate(),
        vm_id: vm.id,
        placement_id: operation.placement_id,
        execution_epoch: operation.execution_epoch,
        operation_id: operation.id,
        generation: operation.generation,
        sequence: 1,
        state: :paused,
        checkpoint: checkpoint(vm),
        compute_empty: true,
        disk_present: true,
        cleanup_complete: false,
        reason: :none
      }

      assert {:ok, _} =
               Ledger.transaction(fn ->
                 Ledger.lock!(Host, vm.host_id)
                 Marshall.Compute.Outcomes.ingest_locked!(vm.host_id, [event])
               end)

      [vm] = Ledger.read!(VirtualMachine, id: vm.id)
      assert RelocationCoordinator.stop_confirmed?(relocation, vm)

      assert {:ok, %{relocation: %{downtime: %{ongoing: true, seconds: seconds}}}} =
               Marshall.Compute.get_vm(%{vm_id: vm.id}, actor: c.owner)

      assert seconds >= 0

      refute RelocationCoordinator.stop_confirmed?(relocation, %{
               vm
               | generation: vm.generation + 1
             })

      refute RelocationCoordinator.stop_confirmed?(
               %{relocation | source_stop_operation_id: nil},
               vm
             )

      assert Enum.sort_by(holds, & &1.id) ==
               Enum.sort_by(Ledger.read!(Reservation, vm_id: vm.id), & &1.id)

      assert {:ok, %{"commands" => [delta]}} = exchange(c)
      assert {:ok, %{to_guid: nil} = delta} = Wire.command(delta)
      assert delta.generation == operation.generation
      assert [%{phase: :copying}] = Ledger.read!(Relocation, id: relocation.id)
      result = put_in(reply(delta).descriptor.stream.to_guid, "201")
      assert {:ok, _} = exchange(c, [result])

      assert {:ok, %{"commands" => [%{"descriptor" => %{"stream" => %{"to_guid" => "201"}}}]}} =
               receive.([])

      assert {:ok, _} = receive.([Map.put(result, :dataset_guid, "300")])

      assert Enum.sort_by(holds, & &1.id) ==
               Enum.sort_by(Ledger.read!(Reservation, vm_id: vm.id), & &1.id)

      message = %{session_id: session["session_id"], epoch: session["epoch"], results: []}

      import = fn results ->
        Marshall.Compute.RelocationImports.exchange(
          credential.token,
          %{message | results: results}
        )
      end

      receipt = Map.put(result, :dataset_guid, "300")
      assert {:error, :invalid_outcome} = import.([receipt])
      assert {:ok, %{"commands" => [%{"dataset_guid" => "300"} = import_command]}} = import.([])
      assert import_command["id"] == delta.id
      assert {:error, :invalid_outcome} = import.([%{receipt | dataset_guid: "301"}])
      assert {:error, :invalid_outcome} = import.([receipt, %{receipt | id: Ash.UUID.generate()}])
      assert [%{destination_imported_at: nil}] = Ledger.read!(SourcePermitRequest, id: delta.id)
      assert {:ok, %{"commands" => [], "acknowledgements" => [id]}} = import.([receipt])
      assert id == delta.id
      assert {:ok, %{"commands" => []}} = import.([receipt])
      assert {:ok, %{"commands" => []}} = exchange(c)
      assert {:ok, %{"commands" => []}} = receive.([])

      assert [%{destination_imported_at: imported}] =
               Ledger.read!(SourcePermitRequest, id: delta.id)

      assert imported != nil

      assert Enum.sort_by(holds, & &1.id) ==
               Enum.sort_by(Ledger.read!(Reservation, vm_id: vm.id), & &1.id)

      assert [current] = Ledger.read!(VirtualMachine, id: vm.id)
      assert current.current_placement_id == c.vm.current_placement_id
      assert current.execution_epoch == c.vm.execution_epoch
      assert {:ok, :committed} = RelocationCoordinator.advance(relocation.id)
      assert {:ok, :committed} = RelocationCoordinator.advance(relocation.id)
      [committed] = Ledger.read!(Relocation, id: relocation.id)
      [current] = Ledger.read!(VirtualMachine, id: vm.id)
      [activation] = Ledger.read!(Operation, id: committed.activation_operation_id)
      assert current.current_placement_id == relocation.destination_placement_id
      assert current.execution_epoch == relocation.destination_epoch
      assert current.generation == vm.generation + 1
      assert current.outcome_sequence == 0 and current.observed_state == :pending
      assert current.desired_state == :running
      assert activation.kind == :resume and activation.initiator == :relocation

      assert activation.command_snapshot["checkpoint"] ==
               OverallsProtocol.Checkpoint.encode(event.checkpoint)

      assert activation.placement_id == current.current_placement_id
      assert activation.execution_epoch == current.execution_epoch
      assert committed.import_request_id == delta.id and committed.committed_at != nil
      assert current.owner_id == c.vm.owner_id and current.image_id == c.vm.image_id
      [source] = Ledger.read!(Reservation, placement_id: relocation.source_placement_id)
      [target] = Ledger.read!(Reservation, placement_id: relocation.destination_placement_id)
      assert source.disk_held and not source.compute_held
      assert source.temporary_disk_bytes == 0
      assert target.disk_held and target.compute_held and target.temporary_disk_bytes == 0
      release_committed_streams(c, credential.token, message)

      assert Enum.any?(
               Oban.Testing.all_enqueued(
                 repo: Marshall.Repo,
                 worker: Marshall.Compute.Workers.Dispatch
               ),
               &(&1.args["primary_key"]["id"] == activation.id)
             )

      # A later source outcome is retained as historical evidence, never reapplied
      # to the destination's reset observation sequence or authority.
      assert {:ok, _} =
               Ledger.transaction(fn ->
                 Ledger.lock!(Host, c.source.host.id)

                 Marshall.Compute.Outcomes.ingest_locked!(
                   c.source.host.id,
                   [%{event | id: Ash.UUID.generate(), sequence: 2}]
                 )
               end)

      assert [unchanged] = Ledger.read!(VirtualMachine, id: vm.id)
      assert unchanged.current_placement_id == current.current_placement_id
      assert unchanged.outcome_sequence == 0 and unchanged.observed_state == :pending

      readiness = fn results ->
        Marshall.Compute.RelocationReadiness.exchange(
          credential.token,
          %{message | results: results}
        )
      end

      assert {:ok, %{"commands" => []}} = readiness.([])

      destination_event = %{
        event
        | id: Ash.UUID.generate(),
          operation_id: activation.id,
          placement_id: activation.placement_id,
          execution_epoch: activation.execution_epoch,
          generation: activation.generation,
          state: :running,
          compute_empty: false
      }

      assert {:ok, _} =
               Ledger.transaction(fn ->
                 Ledger.lock!(Host, c.destination.host.id)

                 Marshall.Compute.Outcomes.ingest_locked!(c.destination.host.id, [
                   destination_event
                 ])
               end)

      assert {:ok, %{"commands" => [probe]}} = readiness.([])
      {:ok, probe} = OverallsProtocol.RelocationReadiness.command(probe)
      [request] = Ledger.read!(Marshall.Compute.ReadinessRequest, id: activation.id)
      [physical] = Ledger.read!(Marshall.Compute.PhysicalOutcome, id: destination_event.id)

      assert DateTime.diff(request.deadline_at, physical.inserted_at, :millisecond) ==
               Application.get_env(:marshall, :relocation_readiness_timeout_ms, 120_000)

      [current] = Ledger.read!(VirtualMachine, id: vm.id)
      refute Marshall.Compute.RelocationReadinessState.terminal_allowed?(current)

      if c.readiness_mode == :ready do
        # @cc [owner:ghuntley,label:verification;security] relocation-roster-readiness-bootstrap
        # The destination's exact physical binding MUST fetch its guest roster
        # while interactive authority remains gated on guest readiness.
        {:ok, ssh_credential} =
          Marshall.Inference.Credentials.rotate(c.destination.host.id, 3600)

        ssh_token = ssh_credential.id <> "." <> ssh_credential.secret

        ssh_binding = Marshall.TerminalFixtures.roster_binding(current)
        assert ssh_binding["host_id"] == c.destination.host.id

        assert {:ok, %{accounts: [%{username: username}]}} =
                 Marshall.SSH.GuestAccess.roster(ssh_token, ssh_binding)

        [account] = Ledger.read!(Marshall.Accounts.GuestAccount, user_id: c.owner.id)
        assert username == account.username
        assert username == "u#{account.uid}"

        assert {:error, :unauthorized} =
                 Marshall.SSH.GuestAccess.roster(
                   ssh_token,
                   Map.put(ssh_binding, "placement_id", c.vm.current_placement_id)
                 )
      end

      [terminal_host] = Ledger.read!(Host, id: c.destination.host.id)

      Ledger.update!(terminal_host, :report, %{
        inventory: Map.put(terminal_host.inventory, "terminal_protocol", 1),
        reported_at: Ledger.now()
      })

      _stream = Marshall.TerminalFixtures.stream_fixture(terminal_host.id)

      open_terminal = fn ->
        [current] = Ledger.read!(VirtualMachine, id: vm.id)
        Marshall.Terminal.Authority.open_session(current, c.owner, "root", "xterm-256color")
      end

      assert {:error, :terminal_open_pending} = open_terminal.()

      receipt = %{
        id: probe.id,
        descriptor: probe.descriptor,
        generation: probe.generation,
        boot_id: Ash.UUID.generate()
      }

      assert {:error, :invalid_outcome} =
               readiness.([%{receipt | generation: receipt.generation + 1}])

      assert {:error, :invalid_outcome} =
               readiness.([receipt, %{receipt | id: Ash.UUID.generate()}])

      assert [%{status: :pending}] =
               Ledger.read!(Marshall.Compute.ReadinessRequest, id: request.id)

      assert {:ok, :committed} = RelocationCoordinator.advance(relocation.id)
      [same] = Ledger.read!(Marshall.Compute.ReadinessRequest, id: request.id)
      assert same.deadline_at == request.deadline_at

      if c.readiness_mode in [:timeout, :retry, :retry_delete] do
        Process.sleep(2100)
        assert {:ok, %{"commands" => [], "acknowledgements" => [_]}} = readiness.([receipt])

        assert [%{status: :failed, failure_reason: :timeout, boot_id: nil}] =
                 Ledger.read!(Marshall.Compute.ReadinessRequest, id: request.id)

        assert {:ok, %{relocation: %{phase: :readiness_failed, downtime: %{ongoing: true}}}} =
                 Marshall.Compute.get_vm(%{vm_id: vm.id}, actor: c.owner)

        refute Marshall.Compute.RelocationReadinessState.terminal_allowed?(current)
        assert {:error, :terminal_open_pending} = open_terminal.()

        if c.readiness_mode in [:retry, :retry_delete],
          do: retry_destination(c, credential.token, message, receipt)
      else
        assert {:ok, %{"commands" => [], "acknowledgements" => [_]}} = readiness.([receipt])
        assert {:ok, _} = readiness.([receipt])

        assert {:error, :outcome_conflict} =
                 readiness.([%{receipt | boot_id: Ash.UUID.generate()}])

        assert [%{status: :ready, boot_id: boot}] =
                 Ledger.read!(Marshall.Compute.ReadinessRequest, id: request.id)

        assert {:ok, %{relocation: %{downtime: %{ongoing: false, seconds: elapsed}}}} =
                 Marshall.Compute.get_vm(%{vm_id: vm.id}, actor: c.owner)

        [stop_proof] = Ledger.read!(Marshall.Compute.PhysicalOutcome, id: event.id)
        [ready_proof] = Ledger.read!(Marshall.Compute.ReadinessRequest, id: request.id)

        assert elapsed ==
                 max(0, DateTime.diff(ready_proof.completed_at, stop_proof.inserted_at, :second))

        assert boot == receipt.boot_id
        assert Marshall.Compute.RelocationReadinessState.terminal_allowed?(current)

        Ledger.update!(terminal_host, :report, %{
          inventory: Map.put(terminal_host.inventory, "terminal_protocol", 2),
          reported_at: Ledger.now()
        })

        assert {:ok, _session} = open_terminal.()
      end

      [retained_source] = Ledger.read!(Reservation, placement_id: relocation.source_placement_id)

      assert retained_source.disk_held and retained_source.temporary_disk_bytes == 0

      if c.readiness_mode in [:ready, :cleanup_delete] do
        cleanup_flow(c, credential.token, message)
      else
        assert {:ok, :committed} = RelocationCoordinator.advance(relocation.id)
        assert [] == Ledger.read!(Marshall.Compute.CleanupRequest, id: relocation.id)
        delete = request_delete(c)
        deletion_outcome(c, credential.token, message, delete, :deleted)
        cleanup_flow(Map.put(c, :logical_delete, true), credential.token, message)
        assert_delete_complete(c, delete)

        if c.readiness_mode == :retry_delete do
          assert Ledger.read!(Marshall.Compute.RelocationRetry, relocation_id: relocation.id) ==
                   []
        end
      end
    end
  end

  # A consumed memory checkpoint cannot be retried as a cold destination boot.
  @spec retry_destination(map(), String.t(), map(), map()) :: :ok
  defp retry_destination(c, _token, _session, old_receipt) do
    alias Marshall.Compute.{ReadinessRequest, RelocationRetry}
    assert [%{status: :failed}] = Ledger.read!(ReadinessRequest, id: old_receipt.id)

    assert {:ok, %{relocation: %{retryable: false}}} =
             Marshall.Compute.get_vm(%{vm_id: c.vm.id}, actor: c.owner)

    before = Ledger.read!(Operation, vm_id: c.vm.id)
    holds = Ledger.read!(Reservation, vm_id: c.vm.id)

    for actor <- [c.owner, user()], _ <- 1..2 do
      assert {:error, _} =
               Marshall.Compute.retry_relocation(
                 %{relocation_id: c.relocation.id, idempotency_key: Ash.UUID.generate()},
                 actor: actor
               )
    end

    assert before == Ledger.read!(Operation, vm_id: c.vm.id)

    assert Enum.sort_by(holds, & &1.id) ==
             Enum.sort_by(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.id)

    assert Ledger.read!(RelocationRetry, relocation_id: c.relocation.id) == []
    {:ok, auth_token, _} = AshAuthentication.Jwt.token_for_user(c.owner)
    owner = Ash.Resource.put_metadata(c.owner, :token, auth_token)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(owner)

    {:ok, view, _} = live(conn, "/machines/#{c.vm.id}/settings")
    refute has_element?(view, "#retry-relocation")
    refute has_element?(view, "#cancel-relocation")
    :ok
  end

  # @cc [owner:ghuntley,label:verification;capacity] cleanup-cycle-healthy-start-fixture
  # Positive Start witnesses MUST refresh only fixture host/pool report times,
  # preserving capacity, inventory, holds and authority. Production freshness
  # refusal MUST remain unchanged; every cycle checks placement, epoch and holds.
  @spec cycle_lifecycle(
          %{vm: VirtualMachine.t(), owner: Marshall.Accounts.User.t()},
          String.t(),
          %{
            required(:session_id) => OverallsProtocol.uuid(),
            required(:epoch) => pos_integer(),
            optional(:results) => []
          }
        ) :: :ok
  defp cycle_lifecycle(c, token, session) do
    [initial] = Ledger.read!(VirtualMachine, id: c.vm.id)
    kinds = if initial.desired_state == :running, do: [:stop, :start], else: [:start, :stop]

    for kind <- kinds do
      # This positive restart witness assumes continuing healthy inventory;
      # long cleanup histories must not accidentally test report expiry here.
      if kind == :start do
        Enum.each(Ledger.read!(Host), fn host ->
          Ledger.update!(host, :report, %{capacity: host.capacity, reported_at: Ledger.now()})
        end)

        Enum.each(Ledger.read!(Marshall.Compute.StoragePool), fn pool ->
          Ledger.update!(pool, :report, %{reported_at: Ledger.now()})
        end)
      end

      assert {:ok, operation} =
               Marshall.Compute.lifecycle(
                 %{vm_id: c.vm.id, kind: kind, idempotency_key: Ash.UUID.generate()},
                 actor: c.owner
               )

      [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

      outcome = %{
        id: Ash.UUID.generate(),
        operation_id: operation.id,
        vm_id: vm.id,
        placement_id: vm.current_placement_id,
        execution_epoch: vm.execution_epoch,
        generation: vm.generation,
        sequence: vm.outcome_sequence + 1,
        state: if(kind == :start, do: :running, else: :stopped),
        compute_empty: kind == :stop,
        disk_present: true,
        cleanup_complete: false,
        reason: :none
      }

      execution = Map.merge(session, %{report: nil, acknowledgements: [], outcomes: []})
      assert {:ok, %{"commands" => [_]}} = ProvisionerControl.exchange_execution(token, execution)

      assert {:ok, _} =
               ProvisionerControl.exchange_execution(token, %{execution | outcomes: [outcome]})

      [current] = Ledger.read!(VirtualMachine, id: vm.id)
      assert current.current_placement_id == initial.current_placement_id
      assert current.execution_epoch == initial.execution_epoch
      assert current.observed_state == outcome.state
      [hold] = Ledger.read!(Reservation, placement_id: current.current_placement_id)
      assert hold.disk_held and hold.compute_held == (kind == :start)

      if kind == :start do
        assert Marshall.Compute.RelocationReadinessState.terminal_allowed?(current)

        crashed = %{
          outcome
          | id: Ash.UUID.generate(),
            sequence: outcome.sequence + 1,
            state: :failed,
            reason: :crashed,
            compute_empty: true
        }

        assert {:ok, %{"commands" => [restart_wire]}} =
                 ProvisionerControl.exchange_execution(token, %{execution | outcomes: [crashed]})

        {:ok, restart} = OverallsProtocol.Execution.command(restart_wire)
        assert restart.kind == :start and restart.generation == operation.generation + 1
        assert restart.placement_id == current.current_placement_id
        assert restart.execution_epoch == current.execution_epoch

        recovered = %{
          outcome
          | id: Ash.UUID.generate(),
            operation_id: restart.id,
            generation: restart.generation,
            sequence: crashed.sequence + 1
        }

        assert {:ok, _} =
                 ProvisionerControl.exchange_execution(token, %{execution | outcomes: [recovered]})

        [recovered_vm] = Ledger.read!(VirtualMachine, id: current.id)
        assert recovered_vm.observed_state == :running
        assert length(recovered_vm.crash_restart_times) == 1
        assert Marshall.Compute.RelocationReadinessState.terminal_allowed?(recovered_vm)
      end
    end

    :ok
  end

  defp release_committed_streams(c, destination_token, destination_message) do
    alias Marshall.Compute.{
      Relocation,
      RelocationCoordinator,
      RelocationRevocations,
      RelocationDestinationRevocations,
      TransferSlot
    }

    source_message = %{
      session_id: c.session["session_id"],
      epoch: c.session["epoch"],
      results: []
    }

    source = fn results ->
      RelocationRevocations.exchange(c.token, %{source_message | results: results})
    end

    destination = fn results ->
      RelocationDestinationRevocations.exchange(destination_token, %{
        destination_message
        | results: results
      })
    end

    source_result = %{
      id: c.relocation.id,
      placement_id: c.relocation.source_placement_id,
      execution_epoch: c.relocation.source_epoch
    }

    destination_result = %{
      id: c.relocation.id,
      placement_id: c.relocation.destination_placement_id,
      execution_epoch: c.relocation.destination_epoch
    }

    slots = fn ->
      for key <- [:source_relocation_id, :destination_relocation_id],
          slot <- Ledger.read!(TransferSlot, [{key, c.relocation.id}]),
          do: slot
    end

    reservations = fn -> Ledger.read!(Reservation, vm_id: c.vm.id) |> Enum.sort_by(& &1.id) end
    before = reservations.()
    assert Enum.all?(slots.(), &is_nil(&1.released_at))
    assert {:error, :invalid_outcome} = source.([source_result])
    assert {:error, :invalid_outcome} = destination.([destination_result])
    assert {:ok, %{"commands" => [_]}} = source.([])
    assert {:ok, %{"commands" => [_]}} = destination.([])

    assert {:error, :invalid_outcome} =
             source.([%{source_result | execution_epoch: source_result.execution_epoch + 1}])

    assert {:error, :invalid_outcome} =
             destination.([
               %{destination_result | placement_id: c.relocation.source_placement_id}
             ])

    assert {:ok, _} = source.([source_result])
    assert {:ok, :committed} = RelocationCoordinator.advance(c.relocation.id)
    assert Enum.all?(slots.(), &is_nil(&1.released_at))
    assert {:ok, _} = destination.([destination_result])
    assert Enum.all?(slots.(), &is_nil(&1.released_at))
    assert {:ok, :committed} = RelocationCoordinator.advance(c.relocation.id)
    released = slots.()
    assert Enum.all?(released, & &1.released_at)
    assert before == reservations.()

    assert [%{finished_at: nil, cancellation_requested_at: nil}] =
             Ledger.read!(Relocation, id: c.relocation.id)

    assert {:ok, _} = source.([source_result])
    assert {:ok, _} = destination.([destination_result])
    assert {:ok, :committed} = RelocationCoordinator.advance(c.relocation.id)
    assert released == slots.()
    assert before == reservations.()
  end

  defp cleanup_flow(c, foreign_token, foreign_message) do
    alias Marshall.Compute.{
      CleanupRequest,
      Relocation,
      RelocationCleanup,
      RelocationCoordinator,
      TransferSlot
    }

    advance_state = if c[:logical_delete], do: :deleting, else: :committed
    message = %{session_id: c.session["session_id"], epoch: c.session["epoch"], results: []}

    exchange = fn results ->
      RelocationCleanup.exchange(c.token, %{message | results: results})
    end

    assert {:ok, %{"commands" => []}} = exchange.([])
    unless c[:logical_delete], do: cycle_lifecycle(c, foreign_token, foreign_message)
    assert {:ok, ^advance_state} = RelocationCoordinator.advance(c.relocation.id)

    assert [%{offered_at: nil, completed_at: nil} = request] =
             Ledger.read!(CleanupRequest, id: c.relocation.id)

    {:ok, descriptor} = OverallsProtocol.Relocation.descriptor(request.descriptor)
    result = %{id: request.id, descriptor: descriptor, generation: request.generation}
    assert {:error, :invalid_outcome} = exchange.([result])
    assert {:ok, %{"commands" => [wire]}} = exchange.([])
    assert {:ok, command} = OverallsProtocol.RelocationCleanup.command(wire)
    assert command.id == c.relocation.id and command.generation == request.generation

    assert {:error, :invalid_outcome} =
             RelocationCleanup.exchange(foreign_token, %{foreign_message | results: [result]})

    assert {:error, :invalid_outcome} = exchange.([%{result | generation: result.generation + 1}])
    assert {:error, :invalid_outcome} = exchange.([result, %{result | id: Ash.UUID.generate()}])
    assert [%{completed_at: nil}] = Ledger.read!(CleanupRequest, id: request.id)
    assert {:ok, ^advance_state} = RelocationCoordinator.advance(c.relocation.id)

    assert [%{disk_held: true}] =
             Ledger.read!(Reservation, placement_id: c.relocation.source_placement_id)

    assert {:ok, %{"commands" => [], "acknowledgements" => [_]}} = exchange.([result])
    assert {:ok, _} = exchange.([result])

    assert [%{disk_held: true}] =
             Ledger.read!(Reservation, placement_id: c.relocation.source_placement_id)

    assert {:ok, ^advance_state} = RelocationCoordinator.advance(c.relocation.id)
    execution = Map.merge(message, %{report: nil, acknowledgements: [], outcomes: []})

    assert {:ok, %{"commands" => [wire]}} =
             ProvisionerControl.exchange_execution(c.token, execution)

    {:ok, delete} = OverallsProtocol.Execution.command(wire)
    assert delete.kind == :delete and delete.placement_id == c.relocation.source_placement_id
    unless c[:logical_delete], do: cycle_lifecycle(c, foreign_token, foreign_message)

    {c, advance_state} =
      if c.readiness_mode == :cleanup_delete do
        user_delete = request_delete(c)
        deletion_outcome(c, foreign_token, foreign_message, user_delete, :deleted)
        {Map.put(c, :logical_delete, true), :deleting}
      else
        {c, advance_state}
      end

    assert [%{status: status}] = Ledger.read!(Operation, id: delete.id)
    assert status in [:pending, :acknowledged]
    [before] = Ledger.read!(VirtualMachine, id: c.vm.id)

    assert delete.execution_epoch == c.relocation.source_epoch and
             delete.generation == request.generation + 1

    unknown = %{
      id: Ash.UUID.generate(),
      vm_id: c.vm.id,
      placement_id: delete.placement_id,
      execution_epoch: delete.execution_epoch,
      generation: delete.generation,
      operation_id: delete.id,
      sequence: 3,
      state: :unknown,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :cleanup_failed
    }

    assert {:ok, _} =
             ProvisionerControl.exchange_execution(c.token, %{execution | outcomes: [unknown]})

    assert {:ok, ^advance_state} = RelocationCoordinator.advance(c.relocation.id)
    assert [%{status: :pending}] = Ledger.read!(Operation, id: delete.id)
    assert [%{disk_held: true}] = Ledger.read!(Reservation, placement_id: delete.placement_id)

    deleted = %{
      unknown
      | id: Ash.UUID.generate(),
        sequence: 4,
        state: :deleted,
        compute_empty: true,
        disk_present: false,
        cleanup_complete: true,
        reason: :none
    }

    assert {:ok, %{"commands" => [], "outcome_acknowledgements" => [_]}} =
             ProvisionerControl.exchange_execution(c.token, %{execution | outcomes: [deleted]})

    assert {:ok, ^advance_state} = RelocationCoordinator.advance(c.relocation.id)
    retirement = Marshall.Compute.RelocationKeyRetirement

    key_result = %{
      id: c.relocation.id,
      placement_id: c.relocation.destination_placement_id,
      execution_epoch: c.relocation.destination_epoch
    }

    assert [%{finished_at: nil}] = Ledger.read!(Relocation, id: c.relocation.id)
    assert [%{disk_held: true}] = Ledger.read!(Reservation, placement_id: delete.placement_id)

    assert {:error, :invalid_outcome} =
             retirement.exchange(foreign_token, %{foreign_message | results: [key_result]})

    assert {:ok, %{"commands" => [key_wire]}} =
             retirement.exchange(foreign_token, %{foreign_message | results: []})

    assert {:ok, key_command} = OverallsProtocol.RelocationKeyRetirement.command(key_wire)
    assert Map.take(key_command, [:id, :placement_id, :execution_epoch]) == key_result

    assert {:error, :invalid_outcome} =
             retirement.exchange(c.token, %{message | results: [key_result]})

    assert {:error, :invalid_outcome} =
             retirement.exchange(foreign_token, %{
               foreign_message
               | results: [key_result, %{key_result | id: Ash.UUID.generate()}]
             })

    assert [%{key_retired_at: nil}] = Ledger.read!(CleanupRequest, id: request.id)

    assert {:error, :invalid_outcome} =
             retirement.exchange(foreign_token, %{
               foreign_message
               | results: [%{key_result | execution_epoch: key_result.execution_epoch + 1}]
             })

    assert {:ok, %{"acknowledgements" => [_]}} =
             retirement.exchange(foreign_token, %{foreign_message | results: [key_result]})

    assert {:ok, _} =
             retirement.exchange(foreign_token, %{foreign_message | results: [key_result]})

    final_state = if c[:logical_delete], do: :deleted, else: :committed
    assert {:ok, ^final_state} = RelocationCoordinator.advance(c.relocation.id)
    assert {:ok, :finished} = RelocationCoordinator.advance(c.relocation.id)
    assert {:ok, %{"commands" => []}} = ProvisionerControl.exchange_execution(c.token, execution)

    assert [%{disk_held: false, compute_held: false, temporary_disk_bytes: 0}] =
             Ledger.read!(Reservation, placement_id: c.relocation.source_placement_id)

    destination_held = c[:logical_delete] != true

    assert [%{disk_held: ^destination_held}] =
             Ledger.read!(Reservation, placement_id: c.relocation.destination_placement_id)

    for key <- [:source_relocation_id, :destination_relocation_id] do
      assert [%{released_at: released}] = Ledger.read!(TransferSlot, [{key, c.relocation.id}])
      assert released != nil
    end

    [finished] = Ledger.read!(Relocation, id: c.relocation.id)
    assert finished.finished_at != nil

    if c[:logical_delete] do
      assert [] == Ledger.read!(VirtualMachine, id: c.vm.id)
      [after_vm] = Ledger.history!(VirtualMachine, id: c.vm.id)

      assert after_vm.archived_at != nil and
               after_vm.current_placement_id == before.current_placement_id
    else
      [after_vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
      assert after_vm == before
    end

    assert {:ok, _} = exchange.([result])

    assert {:error, :stale_connection} =
             RelocationCleanup.exchange(c.token, %{message | epoch: message.epoch + 1})

    unless c[:logical_delete] do
      # Completed relocation history and released old reservations must permit
      # return to that host under a distinct placement, through public admission.
      for fixture <- [c.source, c.destination] do
        [host] = Ledger.read!(Host, id: fixture.host.id)
        Ledger.update!(host, :report, %{reported_at: Ledger.now()})
        [pool] = Ledger.read!(Marshall.Compute.StoragePool, id: fixture.pool.id)
        Ledger.update!(pool, :report, %{reported_at: Ledger.now()})
      end

      assert {:ok, returned} =
               Marshall.Compute.relocate(
                 %{vm_id: c.vm.id, idempotency_key: Ash.UUID.generate()},
                 actor: c.owner
               )

      assert returned.source_placement_id == c.relocation.destination_placement_id
      assert returned.destination_host_id == c.relocation.source_host_id
      assert returned.destination_epoch == c.relocation.destination_epoch + 1

      refute returned.destination_placement_id in [
               c.relocation.source_placement_id,
               c.relocation.destination_placement_id
             ]

      assert [%{disk_held: false, compute_held: false, temporary_disk_bytes: 0}] =
               Ledger.read!(Reservation, placement_id: c.relocation.source_placement_id)
    end
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

  defp reply(command),
    do: %{
      id: command.id,
      descriptor: Map.put(command.intent, :stream, %{source_dataset_guid: "100", to_guid: "200"})
    }

  defp stopped(vm, owner) do
    {:ok, operation} =
      Marshall.Compute.lifecycle(
        %{vm_id: vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
        actor: owner
      )

    event = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: 1,
      state: :stopped,
      compute_empty: true,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    {:ok, _} =
      Ledger.transaction(fn ->
        Ledger.lock!(Host, vm.host_id)
        Marshall.Compute.Outcomes.ingest_locked!(vm.host_id, [event])
      end)

    [vm] = Ledger.read!(VirtualMachine, id: vm.id)
    vm
  end
end
