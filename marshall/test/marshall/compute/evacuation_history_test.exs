defmodule Marshall.Compute.EvacuationHistoryTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Accounts.User
  alias Marshall.Compute

  alias Marshall.Compute.{
    Evacuation,
    EvacuationItem,
    Evacuations,
    Host,
    Ledger,
    Operation,
    Relocation,
    Reservation,
    VirtualMachine
  }

  @typep command ::
           :pause | :continue | :approve | :replan | :advance | :preview | :demote | :promote
  @typep model :: %{
           status: :active | :paused,
           administrator: boolean(),
           approved: boolean(),
           admitted: boolean(),
           key: String.t(),
           old_keys: [String.t()]
         }
  @typep fixture :: %{
           source: Host.t(),
           destination: Host.t(),
           vm: VirtualMachine.t(),
           admin: User.t(),
           operator: User.t(),
           ordinary: User.t(),
           campaign: String.t(),
           item: String.t()
         }
  @tables ~w(compute_hosts compute_storage_pools compute_host_credentials compute_host_sessions
             compute_evacuations compute_evacuations_versions
             compute_evacuation_items compute_evacuation_items_versions
             compute_virtual_machines compute_virtual_machines_versions
             agent_roots agent_roots_versions agent_threads agent_threads_versions agent_audit_events
             compute_workload_placements compute_reservations compute_network_addresses
             compute_operations compute_relocations
             compute_transfer_slots compute_lifecycle_events account_admin_events
             oban_jobs admin_job_snapshots admin_job_events)

  # @cc [owner:ghuntley,label:verification] evacuation-generated-public-history
  # Generated histories MUST enter authorized public actions and compare persisted
  # state with independent approval/revision/pause expectations. Denied or stale
  # requests and advisory previews MUST preserve complete operation, allocation,
  # audit and job rows. Synthetic reports MUST NOT establish native movement.
  property "campaign histories preserve fixed authority and per-revision downtime consent",
    test_cases: 12 do
    check all(
            commands <-
              list_of(
                member_of([
                  :pause,
                  :continue,
                  :approve,
                  :replan,
                  :advance,
                  :preview,
                  :demote,
                  :promote
                ]),
                min_length: 5,
                max_length: 14
              ),
            test_cases: 12
          ) do
      {fixture, initial} = fixture()

      # Every history crosses consent invalidation, then carries admitted work
      # across demotion. Random interleavings add repeat and refusal schedules.
      model =
        Enum.reduce([:approve, :replan, :advance] ++ commands, initial, fn command, model ->
          next = step(command, fixture, model)
          assert_model(fixture, next)
          next
        end)

      model =
        Enum.reduce(
          [:promote, :continue, :approve, :demote, :advance, :advance],
          model,
          fn command, model ->
            next = step(command, fixture, model)
            assert_model(fixture, next)
            next
          end
        )

      assert model.admitted
      [move] = Ledger.read!(Relocation, evacuation_id: fixture.campaign)
      assert move.requested_by_id == fixture.admin.id
      assert move.original_state == :running
      assert move.destination_host_id == fixture.destination.id

      # Campaign acceptance survives demotion. The same retained browser actor
      # must fail all fresh control/approval/replan requests after demotion.
      for command <- [:pause, :continue, :resume, :retire] do
        unchanged(fn ->
          assert {:error, _} =
                   Compute.control_evacuation(%{id: fixture.campaign, command: command},
                     actor: fixture.admin
                   )
        end)
      end

      for actor <- [fixture.admin, fixture.ordinary] do
        unchanged(fn ->
          assert {:error, _} =
                   Compute.approve_evacuation_downtime(args(fixture, model.key), actor: actor)

          assert {:error, _} =
                   Compute.replan_evacuation_workload(args(fixture, model.key), actor: actor)
        end)
      end

      # Pausing admitted work leaves the exact campaign-bound recovery authority.
      promoted = step(:promote, fixture, model)
      paused = step(:pause, fixture, promoted)
      assert {:ok, :paused} = Evacuations.advance(fixture.campaign)
      assert_model(fixture, paused)

      assert {:ok, :ok} =
               Ledger.transaction(fn ->
                 source = Ledger.lock!(Host, fixture.source.id)
                 assert Evacuations.source_allowed?(source, move)
                 refute Evacuations.source_allowed?(source, %{move | evacuation_id: nil})

                 refute Evacuations.source_allowed?(source, %{
                          move
                          | evacuation_id: Ash.UUID.generate()
                        })

                 :ok
               end)

      # Later generated fixtures must not become destinations for earlier ones.
      Ledger.update!(fixture.destination, :configure, %{enabled: false})
    end
  end

  # @cc [owner:ghuntley,label:verification] evacuation-physical-readiness-history
  # Readiness and resume MUST be independently tested against host freshness,
  # pool freshness and physical allocations, including evidence lost after ready.
  # Advancing the workflow or aging a timestamp MUST NOT substitute for evidence.
  property "ready and resume require all current physical emptiness evidence", test_cases: 8 do
    check all(
            obstructions <-
              list_of(member_of([:host_stale, :pool_stale, :allocation]),
                min_length: 2,
                max_length: 7
              ),
            close <- member_of([:resume, :retire]),
            test_cases: 8
          ) do
      source = host_fixture()
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))

      assert {:ok, campaign} =
               Compute.request_evacuation(
                 %{host_id: source.host.id, request_id: Ash.UUID.generate()},
                 actor: admin
               )

      for obstruction <- [:host_stale, :pool_stale, :allocation] ++ obstructions do
        physical(source, obstruction)
        assert {:ok, :awaiting_cleanup} = Evacuations.advance(campaign.id)
        assert [%{status: :active, ready_at: nil}] = Ledger.read!(Evacuation, id: campaign.id)

        unchanged(fn ->
          assert {:error, _} =
                   Compute.control_evacuation(%{id: campaign.id, command: close}, actor: admin)
        end)

        physical(source, :empty)
      end

      assert {:ok, :ready} = Evacuations.advance(campaign.id)

      for obstruction <- [:host_stale, :pool_stale, :allocation] do
        physical(source, obstruction)

        unchanged(fn ->
          assert {:error, _} =
                   Compute.control_evacuation(%{id: campaign.id, command: close}, actor: admin)
        end)

        physical(source, :empty)
      end

      assert {:ok, closed} =
               Compute.control_evacuation(%{id: campaign.id, command: close}, actor: admin)

      assert closed.status == if(close == :resume, do: :resumed, else: :retired)
      assert closed.closed_at != nil
      [host] = Ledger.read!(Host, id: source.host.id)
      assert host.maintenance_mode == if(close == :resume, do: :normal, else: :retired)
      assert host.enabled == (close == :resume)

      unchanged(fn ->
        assert {:error, _} =
                 Compute.control_evacuation(%{id: campaign.id, command: close}, actor: admin)
      end)

      Ledger.update!(host, :configure, %{enabled: false})
    end
  end

  @spec fixture() :: {fixture(), model()}
  defp fixture do
    source = host_fixture()
    ordinary = user()
    admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
    operator = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
    assert {:ok, vm} = Compute.provision(request(), actor: ordinary)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    Ledger.update!(operation, :complete, %{})
    vm = Ledger.update!(vm, :observe, %{observed_state: :running})
    destination = host_fixture()
    # A 2 GiB guest plus 1 GiB boot bundle fits the single stopped copy
    # (ADR-0155); the running guest still needs explicit downtime approval.
    Ledger.update!(destination.pool, :report, %{
      free_bytes: destination.pool.overhead_bytes + 3 * 1_073_741_824,
      reported_at: Ledger.now()
    })

    request = %{host_id: source.host.id, request_id: Ash.UUID.generate()}
    unchanged(fn -> assert {:error, _} = Compute.request_evacuation(request, actor: ordinary) end)
    assert {:ok, campaign} = Compute.request_evacuation(request, actor: admin)

    unchanged(fn ->
      assert {:ok, ^campaign} = Compute.request_evacuation(request, actor: admin)
    end)

    unchanged(fn -> assert {:error, _} = Compute.request_evacuation(request, actor: operator) end)
    [item] = Ledger.read!(EvacuationItem, evacuation_id: campaign.id)

    {%{
       source: source.host,
       destination: destination.host,
       vm: vm,
       admin: admin,
       operator: operator,
       ordinary: ordinary,
       campaign: campaign.id,
       item: item.id
     },
     %{
       status: :active,
       administrator: true,
       approved: false,
       admitted: false,
       key: item.request_key,
       old_keys: []
     }}
  end

  @spec step(command(), fixture(), model()) :: model()
  defp step(command, fixture, model) when command in [:demote, :promote] do
    enabled = command == :promote
    assert {:ok, _} = Marshall.JobHistoryFixture.role(fixture.operator, fixture.admin, enabled)
    %{model | administrator: enabled}
  end

  defp step(:preview, fixture, model) do
    unchanged(fn ->
      assert {:ok, page} =
               Compute.admin_node(%{host_id: fixture.source.id, preview: true},
                 actor: fixture.ordinary
               )

      assert length(page.items) == 1
    end)

    model
  end

  defp step(command, fixture, %{administrator: false} = model)
       when command in [:pause, :continue, :approve, :replan] do
    unchanged(fn -> assert {:error, _} = public(command, fixture, model) end)
    model
  end

  defp step(command, fixture, model) when command in [:pause, :continue] do
    assert {:ok, _} = public(command, fixture, model)
    %{model | status: if(command == :pause, do: :paused, else: :active)}
  end

  defp step(command, fixture, %{admitted: true} = model) when command in [:approve, :replan] do
    unchanged(fn -> assert {:error, _} = public(command, fixture, model) end)
    model
  end

  defp step(:approve, fixture, model) do
    assert {:ok, _} = public(:approve, fixture, model)
    %{model | approved: true}
  end

  defp step(:replan, fixture, model) do
    assert {:ok, replanned} = public(:replan, fixture, model)
    refute replanned.request_key in [model.key | model.old_keys]

    next = %{
      model
      | key: replanned.request_key,
        old_keys: [model.key | model.old_keys],
        approved: false
    }

    for key <- next.old_keys do
      unchanged(fn ->
        assert {:error, _} =
                 Compute.approve_evacuation_downtime(args(fixture, key), actor: fixture.admin)

        assert {:error, _} =
                 Compute.replan_evacuation_workload(args(fixture, key), actor: fixture.admin)
      end)
    end

    next
  end

  defp step(:advance, fixture, model) do
    expected =
      cond do
        model.status == :paused -> :paused
        model.admitted -> :awaiting_cleanup
        model.approved -> :scheduled
        true -> :blocked
      end

    assert {:ok, ^expected} = Evacuations.advance(fixture.campaign)
    %{model | admitted: model.admitted or expected == :scheduled}
  end

  @spec public(command(), fixture(), model()) :: {:ok, map()} | {:error, term()}
  defp public(:approve, fixture, model),
    do: Compute.approve_evacuation_downtime(args(fixture, model.key), actor: fixture.admin)

  defp public(:replan, fixture, model),
    do: Compute.replan_evacuation_workload(args(fixture, model.key), actor: fixture.admin)

  defp public(command, fixture, _model),
    do:
      Compute.control_evacuation(%{id: fixture.campaign, command: command}, actor: fixture.admin)

  @spec args(fixture(), String.t()) :: %{
          id: String.t(),
          item_id: String.t(),
          expected_key: String.t()
        }
  defp args(fixture, key), do: %{id: fixture.campaign, item_id: fixture.item, expected_key: key}

  @spec assert_model(fixture(), model()) :: :ok
  defp assert_model(fixture, model) do
    assert [campaign] = Ledger.read!(Evacuation, id: fixture.campaign)
    assert campaign.status == model.status
    assert campaign.closed_at == nil
    assert [item] = Ledger.read!(EvacuationItem, evacuation_id: fixture.campaign)
    assert item.id == fixture.item

    assert {item.vm_id, item.placement_id, item.execution_epoch, item.original_state} ==
             {fixture.vm.id, fixture.vm.current_placement_id, fixture.vm.execution_epoch,
              :running}

    assert item.request_key == model.key
    assert item.approved_at != nil == model.approved
    assert item.approved_by_id == if(model.approved, do: fixture.admin.id)
    assert item.relocation_id != nil == model.admitted
    moves = Ledger.read!(Relocation, evacuation_id: fixture.campaign)
    assert length(moves) == if(model.admitted, do: 1, else: 0)

    assert length(Ledger.read!(Reservation, vm_id: fixture.vm.id)) ==
             if(model.admitted, do: 2, else: 1)

    assert [%{enabled: true, maintenance_mode: :evacuating}] =
             Ledger.read!(Host, id: fixture.source.id)

    :ok
  end

  @spec physical(map(), :host_stale | :pool_stale | :allocation | :empty) :: :ok
  defp physical(source, obstruction) do
    Ledger.update!(source.host, :report, %{
      reported_at: if(obstruction == :host_stale, do: nil, else: Ledger.now())
    })

    Ledger.update!(source.pool, :report, %{
      reported_at: if(obstruction == :pool_stale, do: nil, else: Ledger.now()),
      allocations: if(obstruction == :allocation, do: %{Ash.UUID.generate() => 4096}, else: %{})
    })

    :ok
  end

  @spec unchanged((-> term())) :: :ok
  defp unchanged(action) do
    before = inventory()
    action.()
    assert inventory() == before
    :ok
  end

  @spec inventory() :: %{String.t() => [[map()]]}
  defp inventory do
    Map.new(@tables, fn table ->
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(Repo, "SELECT to_jsonb(r) FROM #{table} r ORDER BY id", [],
          log: false
        )

      {table, rows}
    end)
  end
end
