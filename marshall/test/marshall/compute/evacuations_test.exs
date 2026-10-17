defmodule Marshall.Compute.EvacuationsTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Compute
  alias Marshall.Accounts.AdminEvent

  alias Marshall.Compute.{
    EvacuationItem,
    Evacuations,
    Host,
    Ledger,
    Operation,
    Relocation,
    Reservation,
    VirtualMachine
  }

  setup do
    source = host_fixture()
    owner = user()

    admin =
      Ledger.update!(user(), :assign_administrator, %{administrator: true})
      |> Marshall.PasskeyFixture.verified_session()

    {:ok, vm} = Compute.provision(request(), actor: owner)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    Ledger.update!(operation, :complete, %{})
    vm = Ledger.update!(vm, :observe, %{observed_state: :running})
    %{source: source, vm: vm, owner: owner, admin: admin}
  end

  test "request fixes cohort and excludes admission while preserving serving", c do
    args = %{host_id: c.source.host.id, request_id: Ash.UUID.generate()}
    assert {:error, _} = Compute.request_evacuation(args, actor: c.owner)
    assert {:ok, campaign} = Compute.request_evacuation(args, actor: c.admin)
    assert {:ok, ^campaign} = Compute.request_evacuation(args, actor: c.admin)

    assert [%{vm_id: vm_id, placement_id: placement}] =
             Ledger.read!(EvacuationItem, evacuation_id: campaign.id)

    assert vm_id == c.vm.id and placement == c.vm.current_placement_id
    [host] = Ledger.read!(Host, id: c.source.host.id)
    assert host.enabled and host.maintenance_mode == :evacuating
    assert {:error, _} = Compute.provision(request(), actor: c.owner)

    assert {:error, _} =
             Compute.relocate(%{vm_id: c.vm.id, idempotency_key: Ash.UUID.generate()},
               actor: c.owner
             )

    assert [] == Ledger.read!(Relocation)

    assert [%{actor_id: actor_id, target_id: target_id, kind: :evacuation_request}] =
             Ledger.read!(AdminEvent, target_id: campaign.id)

    assert actor_id == c.admin.id and target_id == campaign.id
  end

  test "accepted campaign survives requester demotion and schedules one durable move", c do
    destination = host_fixture()
    {:ok, campaign} = request_campaign(c)
    approve_all(c, campaign)
    Ledger.update!(c.admin, :assign_administrator, %{administrator: false})
    assert {:ok, :scheduled} = Evacuations.advance(campaign.id)
    assert {:ok, :awaiting_cleanup} = Evacuations.advance(campaign.id)
    assert [relocation] = Ledger.read!(Relocation, evacuation_id: campaign.id)
    assert relocation.destination_host_id == destination.host.id
    assert relocation.requested_by_id == c.admin.id
    assert relocation.original_state == :running
    assert [%{relocation_id: id}] = Ledger.read!(EvacuationItem, evacuation_id: campaign.id)
    assert id == relocation.id

    assert {:error, _} =
             Compute.control_evacuation(%{id: campaign.id, command: :pause}, actor: c.admin)
  end

  test "pause excludes new moves and source permission stays scoped to its campaign", c do
    host_fixture()
    {:ok, campaign} = request_campaign(c)

    assert {:ok, %{status: :paused}} =
             Compute.control_evacuation(%{id: campaign.id, command: :pause}, actor: c.admin)

    assert {:ok, :paused} = Evacuations.advance(campaign.id)
    assert [] == Ledger.read!(Relocation)

    assert {:ok, _} =
             Compute.control_evacuation(%{id: campaign.id, command: :continue}, actor: c.admin)

    approve_all(c, campaign)
    assert {:ok, :scheduled} = Evacuations.advance(campaign.id)
    [relocation] = Ledger.read!(Relocation)
    {:ok, _} = Compute.control_evacuation(%{id: campaign.id, command: :pause}, actor: c.admin)

    {:ok, :ok} =
      Ledger.transaction(fn ->
        host = Ledger.lock!(Host, c.source.host.id)
        assert Evacuations.source_allowed?(host, relocation)
        refute Evacuations.source_allowed?(host, %{relocation | evacuation_id: nil})
        :ok
      end)
  end

  test "a running guest cannot be reserved or stopped without per-item downtime approval", c do
    # ADR-0155: every relocation stops a running guest, even with ample destination room.
    host_fixture()
    {:ok, campaign} = request_campaign(c)
    assert {:ok, :blocked} = Evacuations.advance(campaign.id)
    assert [] == Ledger.read!(Relocation)
    assert [_] = Ledger.read!(Reservation, vm_id: c.vm.id)
    [item] = Ledger.read!(EvacuationItem, evacuation_id: campaign.id)
    assert item.blocker == :downtime_approval_required

    assert {:ok, _} =
             Compute.approve_evacuation_downtime(
               %{id: campaign.id, item_id: item.id, expected_key: item.request_key},
               actor: c.admin
             )

    assert {:ok, :scheduled} = Evacuations.advance(campaign.id)

    assert [%{original_state: :running, source_stop_operation_id: nil}] =
             Ledger.read!(Relocation, evacuation_id: campaign.id)

    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    assert vm.desired_state == :running
  end

  test "empty host requires fresh physical reports before ready or resume", c do
    empty = host_fixture()

    {:ok, campaign} =
      Compute.request_evacuation(%{host_id: empty.host.id, request_id: Ash.UUID.generate()},
        actor: c.admin
      )

    Ledger.update!(empty.host, :disconnect, %{reported_at: nil})
    assert {:ok, :awaiting_cleanup} = Evacuations.advance(campaign.id)
    Ledger.update!(empty.host, :report, %{reported_at: Ledger.now()})
    assert {:ok, :ready} = Evacuations.advance(campaign.id)
    Ledger.update!(empty.host, :disconnect, %{reported_at: nil})

    assert {:error, _} =
             Compute.control_evacuation(%{id: campaign.id, command: :resume}, actor: c.admin)

    Ledger.update!(empty.host, :report, %{reported_at: Ledger.now()})

    assert {:ok, %{status: :resumed}} =
             Compute.control_evacuation(%{id: campaign.id, command: :resume}, actor: c.admin)

    [host] = Ledger.read!(Host, id: empty.host.id)
    assert host.enabled and host.maintenance_mode == :normal
  end

  test "re-planning clears approval and rejects stale revisions", c do
    {:ok, campaign} = request_campaign(c)
    [item] = Ledger.read!(EvacuationItem, evacuation_id: campaign.id)
    args = %{id: campaign.id, item_id: item.id, expected_key: item.request_key}
    assert {:ok, _} = Compute.approve_evacuation_downtime(args, actor: c.admin)
    Ledger.intent!(c.vm, %{desired_state: :stopped})
    assert {:ok, :blocked} = Evacuations.advance(campaign.id)
    assert {:ok, replanned} = Compute.replan_evacuation_workload(args, actor: c.admin)
    assert replanned.request_key != item.request_key
    [current] = Ledger.read!(EvacuationItem, id: item.id)
    assert current.original_state == :stopped
    assert is_nil(current.approved_at) and is_nil(current.approved_by_id)
    assert current.replanned_by_id == c.admin.id
    assert {:error, _} = Compute.approve_evacuation_downtime(args, actor: c.admin)
    assert {:error, _} = Compute.replan_evacuation_workload(args, actor: c.admin)
    assert [^current] = Ledger.read!(EvacuationItem, id: item.id)
  end

  test "unfinished physical relocation excludes re-planning", c do
    host_fixture()
    {:ok, campaign} = request_campaign(c)
    approve_all(c, campaign)
    assert {:ok, :scheduled} = Evacuations.advance(campaign.id)
    [item] = Ledger.read!(EvacuationItem, evacuation_id: campaign.id)

    assert {:error, _} =
             Compute.replan_evacuation_workload(
               %{id: campaign.id, item_id: item.id, expected_key: item.request_key},
               actor: c.admin
             )

    assert [^item] = Ledger.read!(EvacuationItem, id: item.id)
  end

  test "preview shares destination selection without reservations or jobs", c do
    destination = host_fixture()
    reservations = Ledger.read!(Reservation)
    jobs = Marshall.Repo.all(Oban.Job)

    assert {:ok, page} =
             Compute.admin_node(%{host_id: c.source.host.id, preview: true}, actor: c.admin)

    assert [%{preview: %{destination_id: id, downtime_approval_required: true} = preview}] =
             page.items

    refute Map.has_key?(preview, :strategy)
    assert id == destination.host.id
    assert reservations == Ledger.read!(Reservation)
    assert jobs == Marshall.Repo.all(Oban.Job)
    refute Map.has_key?(page.host, :transfer_endpoint)
    assert {:ok, _} = Compute.admin_node(%{host_id: c.source.host.id}, actor: c.owner)
    {:ok, campaign} = request_campaign(c)
    approve_all(c, campaign)
    assert {:ok, :scheduled} = Evacuations.advance(campaign.id)
    assert [%{destination_host_id: ^id}] = Ledger.read!(Relocation, evacuation_id: campaign.id)
  end

  test "preview of a stopped guest needs no downtime approval and schedules directly", c do
    destination = host_fixture()
    Ledger.intent!(c.vm, %{desired_state: :stopped})
    Ledger.update!(c.vm, :observe, %{observed_state: :stopped})
    [hold] = Ledger.read!(Reservation, placement_id: c.vm.current_placement_id)
    Ledger.update!(hold, :release_compute, %{})

    assert {:ok, page} =
             Compute.admin_node(%{host_id: c.source.host.id, preview: true}, actor: c.admin)

    assert [%{preview: %{downtime_approval_required: false, destination_id: id}}] = page.items
    assert id == destination.host.id
    {:ok, campaign} = request_campaign(c)
    assert {:ok, :scheduled} = Evacuations.advance(campaign.id)
    assert [%{original_state: :stopped}] = Ledger.read!(Relocation, evacuation_id: campaign.id)
  end

  test "evacuation diagnostics are catalogued and deferred until commit", c do
    host_fixture()

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    args = %{host_id: c.source.host.id, request_id: Ash.UUID.generate()}

    {{:ok, campaign}, requested} =
      ExUnit.CaptureLog.with_log(
        [metadata: [:event, :evacuation_id, :host_id]],
        fn -> Compute.request_evacuation(args, actor: c.admin) end
      )

    assert requested =~ "Evacuation campaign requested"
    assert requested =~ "event=evacuation.requested"
    assert requested =~ "evacuation_id=" <> campaign.id
    assert requested =~ "host_id=" <> c.source.host.id

    {{:ok, ^campaign}, replayed} =
      ExUnit.CaptureLog.with_log(
        [metadata: [:event, :evacuation_id, :host_id]],
        fn -> Compute.request_evacuation(args, actor: c.admin) end
      )

    refute replayed =~ "evacuation.requested"

    [item] = Ledger.read!(EvacuationItem, evacuation_id: campaign.id)

    approved =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :evacuation_id, :vm_id]], fn ->
        assert {:ok, _} =
                 Compute.approve_evacuation_downtime(
                   %{id: campaign.id, item_id: item.id, expected_key: item.request_key},
                   actor: c.admin
                 )
      end)

    assert approved =~ "event=evacuation.approved"
    assert approved =~ "evacuation_id=" <> campaign.id
    assert approved =~ "vm_id=" <> c.vm.id

    controlled =
      ExUnit.CaptureLog.capture_log(
        [metadata: [:event, :evacuation_id, :host_id, :operation_status]],
        fn ->
          assert {:ok, _} =
                   Compute.control_evacuation(%{id: campaign.id, command: :pause}, actor: c.admin)
        end
      )

    assert controlled =~ "event=evacuation.controlled"
    assert controlled =~ "operation_status=paused"

    assert {:ok, _} =
             Compute.control_evacuation(%{id: campaign.id, command: :continue}, actor: c.admin)

    Ledger.update!(c.vm, :request_stop, %{})

    blocked =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :evacuation_id, :host_id, :reason]], fn ->
        assert {:ok, :blocked} = Evacuations.advance(campaign.id)
      end)

    assert blocked =~ "event=evacuation.blocked"
    assert blocked =~ "evacuation_id=" <> campaign.id
    assert blocked =~ "host_id=" <> c.source.host.id
    assert blocked =~ "reason=workload_changed"

    replanned =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :evacuation_id, :vm_id]], fn ->
        assert {:ok, _} =
                 Compute.replan_evacuation_workload(
                   %{id: campaign.id, item_id: item.id, expected_key: item.request_key},
                   actor: c.admin
                 )
      end)

    assert replanned =~ "event=evacuation.replanned"
    assert replanned =~ "vm_id=" <> c.vm.id
  end

  # Running guests always need explicit downtime approval (ADR-0155).
  defp approve_all(c, campaign) do
    for item <- Ledger.read!(EvacuationItem, evacuation_id: campaign.id) do
      assert {:ok, _} =
               Compute.approve_evacuation_downtime(
                 %{id: campaign.id, item_id: item.id, expected_key: item.request_key},
                 actor: c.admin
               )
    end

    :ok
  end

  defp request_campaign(c),
    do:
      Compute.request_evacuation(%{host_id: c.source.host.id, request_id: Ash.UUID.generate()},
        actor: c.admin
      )
end
