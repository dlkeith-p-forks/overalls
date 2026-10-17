defmodule Marshall.Compute.DrainsTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Compute

  alias Marshall.Compute.{
    Credentials,
    Drains,
    Enrollment,
    Host,
    HostDrain,
    HostReports,
    Ledger,
    NetworkAddress,
    Operation,
    Outcomes,
    ProvisionerControl,
    Reservation,
    VirtualMachine
  }

  setup do
    fixture = host_fixture(%{machine_id: "sha256:" <> String.duplicate("a", 64)})
    Map.put(fixture, :user, user())
  end

  test "a real worker requests one stop, retains capacity and fences admission until confirmed",
       c do
    {:ok, vm} = Compute.provision(request(), actor: c.user)
    [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)
    id = Ash.UUID.generate()

    assert {:ok, %{status: "draining", enabled: false}} =
             Drains.request(c.host.id, id, "test:operator")

    assert {:ok, _} = Drains.request(c.host.id, id, "test:operator")
    assert {:error, :idempotency_conflict} = Drains.request(c.host.id, id, "different")
    assert {:error, :host_in_maintenance} = Drains.request(c.host.id, Ash.UUID.generate(), "test")
    assert {:error, :host_in_maintenance} = Enrollment.set_enabled(c.host.id, true)
    assert {:error, _} = Compute.provision(request(), actor: c.user)
    assert {:error, _} = lifecycle(vm, :start, c.user)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)
    [stop] = Ledger.read!(Operation, host_drain_id: id)
    assert %{kind: :stop, initiator: :maintenance, requested_by_id: nil, generation: 2} = stop
    assert {:ok, 0} = Drains.advance(id)
    assert %{compute_held: true, disk_held: true} = allocation(vm)
    assert {:error, :host_not_quiescent} = Drains.resume(id)
    ingest(stop, 1, :unknown)
    assert {:ok, %{status: "draining", currently_quiescent: false}} = Drains.status(id)
    assert allocation(vm).compute_held
    ingest(stop, 2, :stopped)
    assert {:ok, %{status: "drained", currently_quiescent: true}} = Drains.status(id)
    assert %{compute_held: false, disk_held: true} = allocation(vm)
    assert [^address] = Ledger.read!(NetworkAddress, vm_id: vm.id)
    assert {:error, :retained_host_resources} = Drains.retire(id)
    ingest(stop, 3, :unknown)
    assert {:ok, %{status: "drained", currently_quiescent: false}} = Drains.status(id)
    assert {:error, :host_not_quiescent} = Drains.resume(id)
    ingest(stop, 4, :stopped)
    assert {:ok, %{status: "resumed", enabled: true}} = Drains.resume(id)
    assert {:ok, %{status: "resumed"}} = Drains.resume(id)
    assert [%{desired_state: :stopped}] = Ledger.read!(VirtualMachine, id: vm.id)
    refute allocation(vm).compute_held
    assert {:ok, _} = lifecycle(vm, :start, c.user)
    assert length(Ledger.read!(HostDrain.Version, version_source_id: id)) == 3
  end

  test "batches and committed continuations stop all 21 guests without duplicate generations",
       c do
    Ledger.update!(c.host, :configure, %{enabled: false})

    c =
      Map.merge(
        c,
        host_fixture(%{name: "large-drain-host"})
      )

    report = %{
      c.report
      | effective_cores: 100,
        effective_memory_bytes: 100_000_000_000,
        capacity: capacity(100, 100_000_000_000),
        sequence: 2,
        sampled_at: Ledger.now(),
        pools: [
          %{
            hd(c.report.pools)
            | total_bytes: 100_000_000_000,
              free_bytes: 100_000_000_000,
              storage: %{hd(c.report.pools).storage | quota_bytes: 100_000_000_000}
          }
        ]
    }

    assert {:ok, :ok} = HostReports.ingest(c.host.id, c.epoch, report)
    for _ <- 1..21, do: assert({:ok, _} = Compute.provision(request(), actor: c.user))
    id = Ash.UUID.generate()
    assert {:ok, _} = Drains.request(c.host.id, id, "batch-test")
    assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :maintenance, with_recursion: true)
    operations = Ledger.read!(Operation, host_drain_id: id)
    assert length(operations) == 21
    assert Enum.all?(operations, &(&1.generation == 2))

    assert Enum.all?(
             Ledger.read!(Reservation, host_id: c.host.id),
             &(&1.compute_held and &1.disk_held)
           )

    assert {:ok, 0} = Drains.advance(id)
  end

  test "drain diagnostics are deferred until the owning transaction commits", c do
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    rejected = Ash.UUID.generate()

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE compute_host_drains ADD CONSTRAINT reject_fixture_drain CHECK (id <> '#{rejected}')",
      []
    )

    rolled_back =
      ExUnit.CaptureLog.capture_log(
        [metadata: [:event, :host_id, :drain_id, :operation_status]],
        fn -> assert {:error, _} = Drains.request(c.host.id, rejected, "deferred") end
      )

    refute rolled_back =~ "host.drain_requested"
    refute rolled_back =~ "Operator process diagnostic"
    [host] = Ledger.read!(Host, id: c.host.id)
    assert host.maintenance_mode == :normal and host.enabled
    assert [] == Ledger.read!(HostDrain, id: rejected)

    id = Ash.UUID.generate()
    metadata = [metadata: [:event, :host_id, :drain_id, :operation_status]]

    requested =
      ExUnit.CaptureLog.capture_log(metadata, fn ->
        assert {:ok, _} = Drains.request(c.host.id, id, "deferred")
      end)

    assert requested =~ "Operator process diagnostic (payload redacted)"
    assert requested =~ "event=host.drain_requested"
    assert requested =~ "host_id=" <> c.host.id
    assert requested =~ "drain_id=" <> id
    assert requested =~ "operation_status=draining"

    replayed =
      ExUnit.CaptureLog.capture_log(metadata, fn ->
        assert {:ok, _} = Drains.request(c.host.id, id, "deferred")
      end)

    refute replayed =~ "host.drain_requested"

    confirmed =
      ExUnit.CaptureLog.capture_log(metadata, fn ->
        assert {:ok, 0} = Drains.advance(id)
      end)

    assert confirmed =~ "event=host.drain_confirmed"
    assert confirmed =~ "operation_status=drained"

    closed =
      ExUnit.CaptureLog.capture_log(metadata, fn ->
        assert {:ok, _} = Drains.resume(id)
      end)

    assert closed =~ "event=host.drain_closed"
    assert closed =~ "operation_status=resumed"
  end

  test "stale confirmation is historical; resume requires a fresh ready observation", c do
    id = Ash.UUID.generate()
    assert {:ok, _} = Drains.request(c.host.id, id, "test")
    Ledger.update!(c.host, :report, %{reported_at: nil})
    assert {:ok, 0} = Drains.advance(id)
    assert {:ok, %{status: "draining", currently_quiescent: false}} = Drains.status(id)
    refresh(c)
    assert {:ok, 0} = Drains.advance(id)
    assert {:ok, %{status: "drained", quiesced_at: confirmed}} = Drains.status(id)
    Ledger.update!(c.host, :report, %{reported_at: nil})

    assert {:ok, %{status: "drained", quiesced_at: ^confirmed, currently_quiescent: false}} =
             Drains.status(id)

    assert {:error, :host_not_quiescent} = Drains.resume(id)
    assert {:error, :host_not_quiescent} = Drains.retire(id)
  end

  test "crash before worker execution does not auto-recover on a draining host", c do
    {:ok, vm} = Compute.provision(request(), actor: c.user)
    [provision] = Ledger.read!(Operation, vm_id: vm.id)
    id = Ash.UUID.generate()
    assert {:ok, _} = Drains.request(c.host.id, id, "test")
    ingest(provision, 1, :failed, :crashed)
    assert [%{generation: 1}] = Ledger.read!(Operation, vm_id: vm.id)
    refute allocation(vm).compute_held
    assert {:ok, %{status: "draining"}} = Drains.status(id)
    assert {:ok, 1} = Drains.advance(id)
    [stop] = Ledger.read!(Operation, host_drain_id: id)
    ingest(provision, 2, :failed, :crashed)
    ingest(stop, 3, :stopped)
    assert {:ok, %{status: "drained"}} = Drains.status(id)
  end

  test "user stop and delete are preserved and retired hosts cannot regain authority", c do
    {:ok, vm} = Compute.provision(request(), actor: c.user)
    {:ok, stop} = lifecycle(vm, :stop, c.user)
    {:ok, credential} = Credentials.rotate(c.host.id, 3600)

    {:ok, session} =
      ProvisionerControl.open_execution(
        credential.token,
        %{session_id: Ash.UUID.generate(), machine_id: c.host.machine_id}
      )

    [host] = Ledger.read!(Host, id: c.host.id)
    id = Ash.UUID.generate()
    assert {:ok, _} = Drains.request(c.host.id, id, "test")
    assert {:ok, 0} = Drains.advance(id)
    assert [] = Ledger.read!(Operation, host_drain_id: id)
    {:ok, delete} = lifecycle(vm, :delete, c.user)
    ingest(stop, 1, :stopped)
    assert allocation(vm).compute_held

    assert {:ok, _} =
             ProvisionerControl.exchange_execution(credential.token, %{
               session_id: host.connection_session_id,
               epoch: session["epoch"],
               report: %{c.report | sampled_at: Ledger.now()},
               acknowledgements: [delete.id],
               outcomes: [outcome(delete, 2, :deleted)]
             })

    assert {:ok, %{status: "drained"}} = Drains.status(id)
    assert {:ok, %{status: "retired", host_mode: "retired", enabled: false}} = Drains.retire(id)
    assert {:ok, %{status: "retired"}} = Drains.retire(id)
    assert {:error, :host_in_maintenance} = Enrollment.set_enabled(c.host.id, true)
    assert {:error, :host_retired} = Credentials.rotate(c.host.id, 3600)
    assert {:error, :unauthorized} = Credentials.with_host(credential.token, fn _ -> :ok end)
    assert {:error, :host_not_quiescent} = Drains.resume(id)
  end

  test "retirement rejects unaccounted physical allocations and addresses on archived VMs", c do
    {:ok, vm} = Compute.provision(request(), actor: c.user)
    [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)
    {:ok, delete} = lifecycle(vm, :delete, c.user)
    ingest(delete, 1, :deleted)
    id = Ash.UUID.generate()
    {:ok, _} = Drains.request(c.host.id, id, "test")
    {:ok, 0} = Drains.advance(id)
    Ledger.update!(c.pool, :report, %{allocations: %{vm.id => vm.disk_bytes}})
    assert {:error, :retained_host_resources} = Drains.retire(id)
    Ledger.update!(c.pool, :report, %{allocations: %{}})
    # Simulate historical inconsistency; archival filtering must not hide it.
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE compute_network_addresses SET archived_at = NULL WHERE id = $1",
      [Ecto.UUID.dump!(address.id)]
    )

    assert {:error, :retained_host_resources} = Drains.retire(id)
  end

  test "Cedar denies ordinary users access to maintenance resources", c do
    assert {:error, _} = Ash.read(HostDrain, actor: c.user)

    assert {:error, _} =
             HostDrain
             |> Ash.Changeset.for_create(
               :request,
               %{id: Ash.UUID.generate(), host_id: c.host.id, operator_reference: "intruder"},
               actor: c.user
             )
             |> Ash.create()

    assert {:error, _} =
             HostDrain
             |> Ash.ActionInput.for_action(
               :advance,
               %{primary_key: %{"id" => Ash.UUID.generate()}},
               actor: c.user
             )
             |> Ash.run_action()

    assert {:error, _} =
             c.host
             |> Ash.Changeset.for_update(
               :maintenance,
               %{maintenance_mode: :draining, enabled: false},
               actor: c.user
             )
             |> Ash.update()
  end

  property "duplicate work and reordered old outcomes cannot release a pending drain reservation",
           c do
    check all(
            actions <-
              list_of(member_of([:duplicate, :old_crash, :unknown]),
                min_length: 1,
                max_length: 12
              ),
            max_runs: 15
          ) do
      {:error, :example_complete} =
        Ledger.transaction(fn ->
          refresh(c)
          {:ok, vm} = Compute.provision(request(), actor: c.user)
          [provision] = Ledger.read!(Operation, vm_id: vm.id)
          id = Ash.UUID.generate()
          {:ok, _} = Drains.request(c.host.id, id, "property")
          {:ok, 1} = Drains.advance(id)
          [stop] = Ledger.read!(Operation, host_drain_id: id)

          for {action, sequence} <- Enum.with_index(actions, 1) do
            case action do
              :duplicate -> assert {:ok, 0} = Drains.advance(id)
              :old_crash -> ingest(provision, sequence, :failed, :crashed)
              :unknown -> ingest(stop, sequence, :unknown)
            end

            assert %{compute_held: true, disk_held: true} = allocation(vm)
            assert {:ok, %{status: "draining"}} = Drains.status(id)
          end

          ingest(stop, length(actions) + 1, :stopped)
          assert {:ok, %{status: "drained"}} = Drains.status(id)
          refute allocation(vm).compute_held
          Ledger.rollback(:example_complete)
        end)
    end
  end

  defp refresh(c) do
    [host] = Ledger.read!(Host, id: c.host.id)

    {:ok, :ok} =
      HostReports.ingest(host.id, host.connection_epoch, %{
        c.report
        | sequence: host.report_sequence + 1,
          sampled_at: Ledger.now()
      })
  end

  defp allocation(vm), do: hd(Ledger.read!(Reservation, vm_id: vm.id))

  defp lifecycle(vm, kind, user),
    do:
      Compute.lifecycle(%{vm_id: vm.id, kind: kind, idempotency_key: Ash.UUID.generate()},
        actor: user
      )

  defp ingest(operation, sequence, state, reason \\ :none) do
    [vm] = Ledger.history!(VirtualMachine, id: operation.vm_id)

    assert {:ok, _} =
             Ledger.transaction(fn ->
               host = Ledger.lock!(Host, vm.host_id)
               Outcomes.ingest_locked!(host.id, [outcome(operation, sequence, state, reason)])
               Drains.confirm_locked!(host)
             end)
  end

  defp outcome(operation, sequence, state, reason \\ :none),
    do: %{
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
