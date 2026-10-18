defmodule Marshall.Compute.CloneHistoryTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Compute

  alias Marshall.Compute.{
    CloneEffect,
    CloneEffects,
    Ledger,
    Operation,
    Reservation,
    TransferSlot,
    VirtualMachine
  }

  alias Marshall.CloneVerificationFixture, as: Fixture

  @type command ::
          {:submit | :cancel | :retry | :advance | :conflict, pos_integer()} | :grant | :revoke
  @type entry :: %{id: String.t(), destination: String.t(), phase: :queued | :failed | :cancelled}
  @type model :: %{
          authorized: boolean(),
          requests: %{optional(pos_integer()) => entry()},
          queue: [pos_integer()]
        }
  @type context :: %{
          optional(:prefix) => String.t(),
          owner: Marshall.Accounts.User.t(),
          actor: Marshall.Accounts.User.t(),
          vm: VirtualMachine.t()
        }
  @type submission :: %{vm_id: String.t(), idempotency_key: String.t()}
  @type boundary :: :preparing | :stopping | :capturing | :copying | :publishing

  # @cc [owner:ghuntley,label:verification] clone-real-history-model
  # Generated commands MUST invoke real Ash actions/coordinator. The independent
  # model MUST retain every accepted identity across failed retries, cancellation,
  # name release and authorization changes, and compare durable side effects.
  # Operation inventories MUST compare complete rows without relying on query order.
  @tag :hegel_case_sandbox
  property "queue histories retain identities while authority and retry eligibility change",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    fixture = host_fixture()
    owner = user()
    manager = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    operations = Ledger.read!(Operation, vm_id: vm.id)
    holds = Ledger.read!(Reservation, vm_id: vm.id)

    commands =
      one_of([
        member_of([:grant, :revoke]),
        tuple({member_of([:submit, :cancel, :retry, :advance, :conflict]), integer(1..4)})
      ])

    history = draw("history", list_of(commands, min_length: 8, max_length: 28))
    prefix = Ash.UUID.generate()
    context = %{owner: owner, actor: manager, vm: vm, prefix: prefix}
    grant(context, :manager)
    model = %{authorized: true, requests: %{}, queue: []}
    # Every generated run reaches a failed retry, a cancellation, and a revoked
    # replay before exploring its additional command history.
    required = [
      {:submit, 1},
      {:advance, 1},
      {:retry, 1},
      :revoke,
      {:submit, 1},
      :grant,
      {:cancel, 1},
      {:retry, 1}
    ]

    final = Enum.reduce(required ++ history, model, &step(&1, &2, context))
    grant(context, :manager)

    for {_key, entry} <- final.requests,
        do: assert({:ok, _} = Compute.cancel_clone(%{request_id: entry.id}, actor: manager))

    assert MapSet.new(Ledger.read!(Operation, vm_id: vm.id)) == MapSet.new(operations)
    assert Ledger.read!(Reservation, vm_id: vm.id) == holds
    assert Ledger.read!(VirtualMachine, owner_id: manager.id) == []
    assert Ledger.read!(TransferSlot, host_id: fixture.host.id) == []
  end

  @spec step(command(), model(), context()) :: model()
  defp step(role, model, context) when role in [:grant, :revoke] do
    grant(context, if(role == :grant, do: :manager, else: :revoked))
    next = %{model | authorized: role == :grant}
    assert_inventory(next, context)
    next
  end

  defp step({operation, key}, model, context) do
    entry = model.requests[key]

    args = %{
      vm_id: context.vm.id,
      idempotency_key: "#{context.prefix}:#{key}",
      name: name(context, key)
    }

    next =
      case operation do
        :submit ->
          result = Compute.clone(args, actor: context.actor)

          cond do
            not model.authorized ->
              assert {:error, _} = result
              model

            entry ->
              assert {:ok, view} = result

              assert {view.id, view.destination_vm_id, view.phase} ==
                       {entry.id, entry.destination, entry.phase}

              model

            true ->
              assert {:ok, view} = result

              refute view.destination_vm_id in Enum.map(model.requests, fn {_, item} ->
                       item.destination
                     end)

              entry = %{id: view.id, destination: view.destination_vm_id, phase: :queued}

              %{
                model
                | requests: Map.put(model.requests, key, entry),
                  queue: model.queue ++ [key]
              }
          end

        :conflict ->
          if entry do
            before = Fixture.request(entry.id)

            assert {:error, _} =
                     Compute.clone(%{args | name: args.name <> "-changed"}, actor: context.actor)

            assert Fixture.request(entry.id) == before
          end

          model

        :advance ->
          if entry do
            assert {:ok, _} = Compute.CloneCoordinator.advance(entry.id)

            if List.first(model.queue) == key do
              current = Fixture.request(entry.id)

              assert current.failure ==
                       if(model.authorized, do: "workload_not_stable", else: "forbidden")

              put_entry(model, key, :failed, List.delete(model.queue, key))
            else
              model
            end
          else
            model
          end

        action when action in [:cancel, :retry] ->
          if entry do
            result =
              apply(Compute, if(action == :cancel, do: :cancel_clone, else: :retry_clone), [
                %{request_id: entry.id},
                [actor: context.actor]
              ])

            cond do
              not model.authorized ->
                assert {:error, _} = result
                model

              action == :cancel ->
                assert {:ok, _} = result
                put_entry(model, key, :cancelled, List.delete(model.queue, key))

              entry.phase == :failed ->
                assert {:ok, _} = result
                put_entry(model, key, :queued, model.queue ++ [key])

              true ->
                assert {:error, _} = result
                model
            end
          else
            model
          end
      end

    for {_key, expected} <- next.requests do
      actual = Fixture.request(expected.id)

      assert {actual.destination_vm_id, actual.phase, actual.active} ==
               {expected.destination, expected.phase, false}

      assert is_nil(actual.name_released_at) == (expected.phase != :cancelled)
      assert actual.published_at == nil
      assert Ledger.read!(CloneEffect, clone_request_id: actual.id) == []
    end

    assert_inventory(next, context)
    next
  end

  # @cc [owner:ghuntley,label:verification] clone-history-complete-inventory
  # Every command MUST compare all durable request identities for its unique
  # history prefix, including extra rows after refusals. Earlier histories MUST
  # remain outside this oracle; duplicate keys across actors MUST NOT collapse.
  @spec assert_inventory(model(), context()) :: :ok
  defp assert_inventory(model, context) do
    prefix = context.prefix <> ":"

    actual =
      Compute.CloneRequest
      |> Ledger.read!()
      |> Enum.filter(&String.starts_with?(&1.request_key, prefix))
      |> Enum.map(fn request ->
        {request.request_key, request.id, request.source_vm_id, request.requested_by_id,
         request.destination_vm_id, request.phase, request.active}
      end)
      |> Enum.sort()

    expected =
      model.requests
      |> Enum.map(fn {key, entry} ->
        {prefix <> Integer.to_string(key), entry.id, context.vm.id, context.actor.id,
         entry.destination, entry.phase, false}
      end)
      |> Enum.sort()

    assert actual == expected
    :ok
  end

  @spec put_entry(model(), pos_integer(), :queued | :failed | :cancelled, [pos_integer()]) ::
          model()
  defp put_entry(model, key, phase, queue),
    do: %{model | requests: Map.update!(model.requests, key, &%{&1 | phase: phase}), queue: queue}

  @spec name(context(), pos_integer()) :: String.t()
  defp name(context, key), do: "clone-#{binary_part(context.prefix, 0, 8)}-#{key}"

  @spec grant(context(), :manager | :revoked) :: :ok
  defp grant(context, role) do
    assert {:ok, _} =
             Marshall.Access.set_access(
               %{
                 vm_id: context.vm.id,
                 email: to_string(context.actor.email),
                 role: role,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: context.owner
             )

    :ok
  end

  @type evidence :: :revoke_source | :revoke_destination | :discard | :prune | :restore

  # @cc [owner:ghuntley,label:verification;recovery] clone-capture-uncertainty-retains-authority
  # Unconfirmed capture receipts MUST traverse authenticated exchange and retain
  # the same offered effect, destination, reservations and transfer slots without
  # publishing or fabricating a snapshot. Only an intent-bound successful receipt
  # may clear the diagnostic and allow the coordinator to record that snapshot.
  # Operation inventories MUST compare complete rows without relying on query order.
  @tag :hegel_case_sandbox
  property "unconfirmed capture retries the same effect until a bound receipt clears progress",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    attempts = draw("attempts", integer(1..4))
    fixture = host_fixture()
    owner = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    [provision] = Ledger.read!(Operation, vm_id: vm.id)
    Fixture.settle(vm, provision, :running)

    {:ok, clone} =
      Compute.clone(%{vm_id: vm.id, idempotency_key: Ash.UUID.generate()}, actor: owner)

    reach(clone.id, :capturing)
    Fixture.advance(clone.id)
    [capture] = Ledger.read!(CloneEffect, clone_request_id: clone.id, kind: :capture)
    {:ok, credential} = Marshall.Compute.Credentials.rotate(fixture.host.id, 3600)
    session = Ash.UUID.generate()

    {:ok, opened} =
      Marshall.Compute.ProvisionerControl.open_execution(credential.token, %{
        session_id: session,
        machine_id: fixture.host.machine_id
      })

    message = %{session_id: session, epoch: opened["epoch"], results: []}
    assert {:ok, %{"commands" => [offered]}} = CloneEffects.exchange(credential.token, message)
    assert offered["id"] == capture.id
    holds = capture_holds(vm.id, clone.destination_vm_id)
    slots = Ledger.read!(TransferSlot, clone_request_id: clone.id)
    operations = Ledger.read!(Operation, vm_id: vm.id)

    uncertain = %{
      "id" => capture.id,
      "kind" => "capture",
      "result" => %{"error" => "unconfirmed", "reason" => "snapshot_unconfirmed"}
    }

    for _attempt <- 1..attempts do
      assert {:ok, %{"commands" => [retry], "acknowledgements" => [id]}} =
               CloneEffects.exchange(credential.token, %{message | results: [uncertain]})

      assert id == capture.id and retry["id"] == capture.id
      assert retry["intent"] == offered["intent"]
      Fixture.advance(clone.id)
      current = Fixture.request(clone.id)
      assert current.phase == :capturing and current.failure == "capture_snapshot_unconfirmed"
      assert current.destination_vm_id == clone.destination_vm_id

      assert current.snapshot == nil and current.published_at == nil and
               current.finished_at == nil

      [pending] = Ledger.read!(CloneEffect, id: capture.id)
      assert pending.result == nil and pending.completed_at == nil
      assert capture_holds(vm.id, clone.destination_vm_id) == holds
      assert Ledger.read!(TransferSlot, clone_request_id: clone.id) == slots
      assert MapSet.new(Ledger.read!(Operation, vm_id: vm.id)) == MapSet.new(operations)
      assert Ledger.read!(Operation, vm_id: clone.destination_vm_id) == []
    end

    descriptor =
      Map.put(offered["intent"], "stream", %{
        "source_dataset_guid" => "100",
        "to_guid" => "101"
      })

    assert {:ok, _} = OverallsProtocol.DiskTransfer.descriptor(descriptor)
    receipt = %{uncertain | "result" => %{"descriptor" => descriptor}}

    assert {:ok, %{"acknowledgements" => [id]}} =
             CloneEffects.exchange(credential.token, %{message | results: [receipt]})

    assert id == capture.id
    [confirmed] = Ledger.read!(CloneEffect, id: capture.id)
    assert confirmed.result == receipt["result"] and confirmed.completed_at != nil
    current = Fixture.request(clone.id)
    assert current.failure == nil and current.phase == :capturing
    assert current.snapshot == nil and current.published_at == nil
    assert capture_holds(vm.id, clone.destination_vm_id) == holds
    assert Ledger.read!(TransferSlot, clone_request_id: clone.id) == slots

    # Duplicate success and a late old uncertain receipt cannot erase the
    # retained capture or restore its cleared diagnostic.
    for replay <- [receipt, uncertain] do
      assert {:ok, _} = CloneEffects.exchange(credential.token, %{message | results: [replay]})
      assert Fixture.request(clone.id).failure == nil
      assert Ledger.read!(CloneEffect, id: capture.id) == [confirmed]
    end

    Fixture.advance(clone.id)
    current = Fixture.request(clone.id)
    assert current.phase == :copying and current.snapshot == receipt["result"]
    assert current.failure == nil and current.published_at == nil
    assert current.destination_vm_id == clone.destination_vm_id
    Fixture.cleanup(fixture.host.id, owner.id)
  end

  # @cc [owner:ghuntley,label:verification;recovery] clone-effect-uncertainty-retains-commitments
  # Every non-capture effect kind and both revoke endpoints MUST retain the same
  # offered identity, phase, snapshot and commitments across authenticated uncertain
  # receipts. Matching success MUST clear its label; duplicate success and late
  # uncertainty MUST NOT erase completion or recreate progress failure.
  # Operation inventories MUST compare complete rows without relying on query order.
  @tag :hegel_case_sandbox
  property "forward and cleanup uncertainty await the same bound effect without releasing holds",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()

    cases = [
      {:prepare, :destination},
      {:probe, :source},
      {:connect, :destination},
      {:copy, :destination},
      {:adopt, :destination},
      {:revoke, :source},
      {:revoke, :destination},
      {:discard, :destination},
      {:prune, :source}
    ]

    attempts = draw("attempts", integer(1..3))

    for {kind, endpoint} <- cases do
      fixture = host_fixture()
      owner = user()
      {:ok, vm} = Compute.provision(request(), actor: owner)
      [provision] = Ledger.read!(Operation, vm_id: vm.id)
      Fixture.settle(vm, provision, :running)

      {:ok, clone} =
        Compute.clone(%{vm_id: vm.id, idempotency_key: Ash.UUID.generate()}, actor: owner)

      reach_effect(clone.id, kind, owner)

      [effect] =
        Ledger.read!(CloneEffect, clone_request_id: clone.id, kind: kind, endpoint: endpoint)

      {:ok, credential} = Marshall.Compute.Credentials.rotate(fixture.host.id, 3600)
      session = Ash.UUID.generate()

      {:ok, opened} =
        Marshall.Compute.ProvisionerControl.open_execution(credential.token, %{
          session_id: session,
          machine_id: fixture.host.machine_id
        })

      message = %{session_id: session, epoch: opened["epoch"], results: []}
      assert {:ok, %{"commands" => commands}} = CloneEffects.exchange(credential.token, message)
      offered = Enum.find(commands, &(&1["id"] == effect.id))
      assert offered
      before = Fixture.request(clone.id)
      holds = capture_holds(vm.id, clone.destination_vm_id)
      slots = Ledger.read!(TransferSlot, clone_request_id: clone.id)
      operations = Ledger.read!(Operation, vm_id: vm.id)

      uncertain = %{
        "id" => effect.id,
        "kind" => Atom.to_string(kind),
        "result" => %{"error" => "unconfirmed", "reason" => "effect_unconfirmed"}
      }

      for _attempt <- 1..attempts do
        assert {:ok, %{"commands" => retries, "acknowledgements" => [id]}} =
                 CloneEffects.exchange(credential.token, %{message | results: [uncertain]})

        assert id == effect.id
        retry = Enum.find(retries, &(&1["id"] == effect.id))
        assert retry && retry["intent"] == offered["intent"]
        Fixture.advance(clone.id)
        current = Fixture.request(clone.id)
        assert current.failure == "#{kind}_effect_unconfirmed" and current.phase == before.phase

        assert current.snapshot == before.snapshot and
                 current.destination_vm_id == clone.destination_vm_id

        assert current.published_at == nil and current.finished_at == nil
        [pending] = Ledger.read!(CloneEffect, id: effect.id)

        assert pending.status == :offered and pending.result == nil and
                 pending.completed_at == nil

        assert pending.payload == effect.payload
        assert capture_holds(vm.id, clone.destination_vm_id) == holds
        assert Ledger.read!(TransferSlot, clone_request_id: clone.id) == slots
        assert MapSet.new(Ledger.read!(Operation, vm_id: vm.id)) == MapSet.new(operations)
        assert Ledger.read!(Operation, vm_id: clone.destination_vm_id) == []
      end

      result =
        case kind do
          :prepare -> %{"public_key" => transfer_endpoint()["host_key"]}
          :copy -> %{"dataset_guid" => "102"}
          _ -> %{}
        end

      receipt = %{uncertain | "result" => result}
      assert {:ok, _} = CloneEffects.exchange(credential.token, %{message | results: [receipt]})
      [confirmed] = Ledger.read!(CloneEffect, id: effect.id)

      assert confirmed.status == :completed and confirmed.completed_at != nil and
               confirmed.result == result

      for replay <- [receipt, uncertain] do
        assert {:ok, _} =
                 CloneEffects.exchange(credential.token, %{message | results: [replay]})

        assert Fixture.request(clone.id).failure == nil
        assert Ledger.read!(CloneEffect, id: effect.id) == [confirmed]
      end

      assert capture_holds(vm.id, clone.destination_vm_id) == holds
      assert Ledger.read!(TransferSlot, clone_request_id: clone.id) == slots
      Fixture.cleanup(fixture.host.id, owner.id)
    end
  end

  @spec reach_effect(String.t(), Fixture.effect_kind(), Marshall.Accounts.User.t()) :: :ok
  defp reach_effect(id, kind, _owner) when kind in [:prepare, :probe, :connect] do
    reach(id, :preparing)

    if kind in [:probe, :connect] do
      Fixture.effect(id, :prepare, {:public_key, transfer_endpoint()["host_key"]})
      Fixture.advance(id)
    end

    if kind == :connect do
      offer_fixture_effect(id, :probe)
      Fixture.effect(id, :probe, :empty)
      Fixture.advance(id)
    end

    :ok
  end

  defp reach_effect(id, kind, owner) do
    reach(id, :capturing)
    offer_fixture_effect(id, :capture)
    Fixture.capture(id)
    Fixture.settle_source(id, :running)
    Fixture.advance(id)

    if kind == :adopt do
      Fixture.effect(id, :copy, {:dataset_guid, "102"})
      Fixture.advance(id)
    end

    if kind in [:revoke, :discard, :prune] do
      assert {:ok, _} = Compute.cancel_clone(%{request_id: id}, actor: owner)
      Fixture.advance(id)

      if kind in [:discard, :prune] do
        Fixture.effect(id, :revoke, :empty)
        Fixture.advance(id)
      end

      if kind == :prune do
        Fixture.effect(id, :discard, :empty)
        Fixture.advance(id)
      end
    end

    :ok
  end

  @spec offer_fixture_effect(String.t(), :probe | :capture) :: :ok
  defp offer_fixture_effect(id, kind) do
    # Completed probe/capture receipts are replayable. The synthetic prerequisite
    # must retain its original offer just as a native host receipt would.
    [effect] = Ledger.read!(CloneEffect, clone_request_id: id, kind: kind)
    Ledger.update!(effect, :offer, %{offered_at: Ledger.now()})
    :ok
  end

  @spec capture_holds(String.t(), String.t()) :: [Reservation.t()]
  defp capture_holds(source, destination) do
    Enum.flat_map([source, destination], &Ledger.read!(Reservation, vm_id: &1))
    |> Enum.sort_by(& &1.id)
  end

  # @cc [owner:ghuntley,label:verification;recovery] clone-cancellation-obligation-model
  # Cancellation histories MUST retain source/destination holds until both native
  # endpoints, destination discard, snapshot prune and source restoration have
  # supplied evidence. Revoked user actions MUST fail while admitted recovery runs.
  @tag :hegel_case_sandbox
  property "cancellation retains obligations through reordered evidence and revoked requester",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()

    boundary =
      draw("boundary", member_of([:preparing, :stopping, :capturing, :copying, :publishing]))

    revoke? = draw("revoke?", boolean())

    commands =
      draw(
        "commands",
        list_of(
          member_of([
            :advance,
            :replay,
            :revoke_source,
            :revoke_destination,
            :discard,
            :prune,
            :restore
          ]),
          min_length: 5,
          max_length: 20
        )
      )

    host = host_fixture()
    owner = user()
    actor = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    [provision] = Ledger.read!(Operation, vm_id: vm.id)
    Fixture.settle(vm, provision, :running)
    context = %{owner: owner, actor: actor, vm: vm}
    grant(context, :manager)
    args = %{vm_id: vm.id, idempotency_key: Ash.UUID.generate()}
    {:ok, clone} = Compute.clone(args, actor: actor)
    reach(clone.id, boundary)
    snapshot = Fixture.request(clone.id).snapshot
    assert {:ok, _} = Compute.cancel_clone(%{request_id: clone.id}, actor: actor)
    if revoke?, do: grant(context, :revoked)
    Fixture.advance(clone.id)
    initial = if boundary == :preparing, do: MapSet.new([:restore]), else: MapSet.new()

    final_commands = [
      :restore,
      :restore,
      :revoke_source,
      :revoke_destination,
      :discard,
      :prune,
      :advance
    ]

    seen =
      Enum.reduce(commands ++ final_commands, initial, fn command, seen ->
        updated = cancellation_step(command, clone.id, args, actor, revoke?, seen)
        assert_obligations(clone, vm, updated, snapshot)
        updated
      end)

    assert MapSet.size(seen) == 5
    assert Fixture.request(clone.id).phase == :cancelled
    assert {:error, _} = Compute.retry_clone(%{request_id: clone.id}, actor: actor)
    grant(context, :manager)
    assert {:ok, replay} = Compute.clone(args, actor: actor)

    assert {replay.id, replay.destination_vm_id, replay.phase} ==
             {clone.id, clone.destination_vm_id, :cancelled}

    # The old actor/key remains cancelled even after its released name is
    # explicitly reused by another request identity.
    assert {:ok, replacement} =
             Compute.clone(
               %{args | idempotency_key: Ash.UUID.generate()} |> Map.put(:name, clone.name),
               actor: actor
             )

    refute replacement.id == clone.id
    assert {:ok, _} = Compute.cancel_clone(%{request_id: replacement.id}, actor: actor)
    Fixture.cleanup(host.host.id, actor.id)
    Fixture.query("DELETE FROM users WHERE id=$1", [Ecto.UUID.dump!(owner.id)])
  end

  @spec reach(String.t(), boundary()) :: :ok
  defp reach(id, :preparing), do: Fixture.advance(id)
  defp reach(id, :stopping), do: Fixture.prepare(id)

  defp reach(id, :capturing) do
    reach(id, :stopping)
    Fixture.settle_source(id, :stopped)
    Fixture.advance(id)
  end

  defp reach(id, :copying) do
    reach(id, :capturing)
    Fixture.capture(id)
  end

  defp reach(id, :publishing) do
    reach(id, :copying)
    Fixture.effect(id, :copy, {:dataset_guid, "102"})
    Fixture.advance(id)
  end

  @spec cancellation_step(
          evidence() | :advance | :replay,
          String.t(),
          submission(),
          Marshall.Accounts.User.t(),
          boolean(),
          MapSet.t(evidence())
        ) :: MapSet.t(evidence())
  defp cancellation_step(:replay, id, args, actor, revoked?, seen) do
    before = Fixture.request(id)

    for result <- [
          Compute.clone(args, actor: actor),
          Compute.get_clone(%{request_id: id}, actor: actor),
          Compute.cancel_clone(%{request_id: id}, actor: actor)
        ] do
      if revoked?, do: assert({:error, _} = result), else: assert({:ok, _} = result)
    end

    assert Fixture.request(id) == before
    seen
  end

  defp cancellation_step(:restore, id, _args, _actor, _revoked?, seen) do
    if MapSet.member?(seen, :restore) do
      seen
    else
      clone = Fixture.request(id)
      [op] = Ledger.read!(Operation, id: clone.source_operation_id)
      assert op.kind in [:stop, :start]
      Fixture.settle_source(id, if(op.kind == :stop, do: :stopped, else: :running))
      assert [%{status: :completed}] = Ledger.read!(Operation, id: op.id)
      Fixture.advance(id)
      if op.kind == :start, do: MapSet.put(seen, :restore), else: seen
    end
  end

  defp cancellation_step(:advance, id, _args, _actor, _revoked?, seen) do
    Fixture.advance(id)
    seen
  end

  defp cancellation_step(command, id, _args, _actor, _revoked?, seen) do
    {kind, endpoint} =
      case command do
        :revoke_source -> {:revoke, :source}
        :revoke_destination -> {:revoke, :destination}
        :discard -> {:discard, :destination}
        :prune -> {:prune, :source}
      end

    if Ledger.read!(CloneEffect, clone_request_id: id, kind: kind, endpoint: endpoint) == [] do
      seen
    else
      Fixture.effect(id, kind, :empty, endpoint)
      Fixture.advance(id)
      MapSet.put(seen, command)
    end
  end

  @spec assert_obligations(
          Fixture.view(),
          VirtualMachine.t(),
          MapSet.t(evidence()),
          Fixture.json_object() | nil
        ) :: :ok
  defp assert_obligations(clone, vm, seen, snapshot) do
    current = Fixture.request(clone.id)
    complete? = MapSet.size(seen) == 5
    assert current.phase == if(complete?, do: :cancelled, else: :cancelling)
    assert current.published_at == nil
    assert current.snapshot == snapshot
    assert current.active == not complete?
    [source] = Ledger.read!(VirtualMachine, id: vm.id)
    restored? = MapSet.member?(seen, :restore)
    assert not is_nil(current.source_restored_at) == restored?

    if restored? do
      assert source.observed_state == :running
      assert Enum.all?(Ledger.read!(Operation, vm_id: vm.id), &(&1.status == :completed))
    end

    assert source.archived_at == nil
    assert source.owner_id == vm.owner_id
    [hold] = Ledger.read!(Reservation, vm_id: vm.id)
    assert hold.disk_held
    assert hold.temporary_disk_bytes == 0 == complete?
    [destination_hold] = Ledger.read!(Reservation, vm_id: clone.destination_vm_id)
    assert destination_hold.disk_held == not complete?
    slots = Ledger.read!(TransferSlot, clone_request_id: clone.id)
    assert slots != []
    # Slots release on both revocation receipts (the stream is over), which
    # may precede the remaining discard, prune and restoration obligations.
    quiescent? =
      MapSet.member?(seen, :revoke_source) and MapSet.member?(seen, :revoke_destination)

    cond do
      complete? -> assert Enum.all?(slots, &(not is_nil(&1.released_at)))
      not quiescent? -> assert Enum.all?(slots, &is_nil(&1.released_at))
      true -> :ok
    end

    assert Ledger.read!(VirtualMachine, id: clone.destination_vm_id) == [] == complete?
    :ok
  end

  @shape_keys [:image_id, :profile, :vcpu, :memory_bytes, :disk_bytes]

  # @cc [owner:ghuntley,label:verification] clone-shape-image-history-oracle
  # Generated profile, shape, power and image-churn histories MUST drive the
  # real coordinator against committed admissions and compare the completed
  # destination row and offered workload descriptor against the source row
  # captured at activation. Catalog disable or rotation MUST refuse fresh
  # admission while leaving queued identity, replay and completion untouched.
  @tag :hegel_case_sandbox
  property "generated profile and shape histories retain the captured source row through churn",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    profile = draw("profile", member_of([:customer, :standard, :oss]))
    vcpu = draw("vcpu", member_of([1, 2]))
    memory_mib = draw("memory_mib", member_of([512, 768, 1024]))
    disk_gib = draw("disk_gib", member_of([2, 3]))
    churn = draw("churn", member_of([:none, :disabled, :rotated]))
    power = draw("power", member_of([:running, :stopped]))
    budget = 34_359_738_368
    fixture = host_fixture()
    report_pool_capacity(fixture, budget)
    owner = user()

    {:ok, vm} =
      Compute.provision(
        request(%{
          profile: profile,
          vcpu: vcpu,
          memory_bytes: memory_mib * 1_048_576,
          disk_bytes: disk_gib * 1_073_741_824
        }),
        actor: owner
      )

    [provision] = Ledger.read!(Operation, vm_id: vm.id)
    Fixture.settle(vm, provision, :running)

    if power == :stopped do
      {:ok, stop} =
        Compute.lifecycle(%{vm_id: vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
          actor: owner
        )

      Fixture.settle(vm, stop, :stopped)
    end

    captured =
      vm.id
      |> source_row()
      |> Map.take(@shape_keys)

    case churn do
      :disabled ->
        [image] = Ledger.read!(Marshall.Compute.Image, id: captured.image_id)
        Ledger.update!(image, :configure, %{enabled: false})

        assert {:error, provision_error} =
                 Compute.provision(
                   request(%{
                     profile: profile,
                     vcpu: vcpu,
                     memory_bytes: memory_mib * 1_048_576,
                     disk_bytes: disk_gib * 1_073_741_824
                   }),
                   actor: owner
                 )

        assert Exception.message(provision_error) =~ "image_unavailable"

      :rotated ->
        rotated = rotated_image(captured.image_id)
        report_inventory_images(fixture, rotated.id)

      :none ->
        :ok
    end

    key = Ash.UUID.generate()
    {:ok, clone} = Compute.clone(%{vm_id: vm.id, idempotency_key: key}, actor: owner)
    {:ok, replay} = Compute.clone(%{vm_id: vm.id, idempotency_key: key}, actor: owner)
    assert {replay.id, replay.destination_vm_id} == {clone.id, clone.destination_vm_id}

    drive_clone(clone.id, power, owner)

    completed = Fixture.request(clone.id)
    assert completed.phase == :complete
    assert completed.active == false
    assert completed.published_at && completed.finished_at
    [destination] = Ledger.read!(VirtualMachine, id: clone.destination_vm_id)
    assert Map.take(destination, @shape_keys) == captured
    assert destination.id != vm.id
    assert destination.owner_id == owner.id
    assert Map.take(source_row(vm.id), @shape_keys) == captured

    descriptor =
      completed.specification["workload"]
      |> Map.take(Enum.map(@shape_keys, &Atom.to_string/1))

    assert descriptor ==
             Map.new(captured, fn
               {shape_key, value} when is_atom(value) ->
                 {Atom.to_string(shape_key), Atom.to_string(value)}

               {shape_key, value} ->
                 {Atom.to_string(shape_key), value}
             end)

    assert completed.specification["source"]["vm_id"] == vm.id
    assert completed.specification["destination"]["vm_id"] == clone.destination_vm_id
    assert {:ok, _} = OverallsProtocol.DiskTransfer.intent(CloneEffects.intent(completed))

    assert Ledger.read!(CloneEffect, clone_request_id: clone.id, kind: :capture) |> length() ==
             1

    assert Ledger.read!(TransferSlot, clone_request_id: clone.id, released_at: [is_nil: true]) ==
             []

    # Property iterations share one sandbox generation; never leak a disabled
    # image or extra image rows into the next generated history.
    if churn == :disabled do
      [image] = Ledger.read!(Marshall.Compute.Image, id: captured.image_id)
      Ledger.update!(image, :configure, %{enabled: true})
    end

    # Completed clone drives leave source/destination operations that carry the
    # request identity; release their physical outcomes and the operation rows
    # by requester before the shared host-scoped teardown deletes queue rows.
    Fixture.query(
      "DELETE FROM compute_physical_outcomes o USING compute_operations op, compute_clone_requests r WHERE op.clone_request_id = r.id AND r.requested_by_id = $1 AND o.operation_id = op.id",
      [Ecto.UUID.dump!(owner.id)]
    )

    Fixture.query(
      "DELETE FROM compute_operations WHERE clone_request_id IN (SELECT id FROM compute_clone_requests WHERE requested_by_id = $1)",
      [Ecto.UUID.dump!(owner.id)]
    )

    Fixture.cleanup(fixture.host.id, owner.id)
  end

  @spec source_row(String.t()) :: VirtualMachine.t()
  defp source_row(id), do: hd(Ledger.read!(VirtualMachine, id: id))

  # Drives the unchanged coordinator through capture, restoration, copy,
  # publication and cleanup with synthetic receipts; native evidence stays with
  # the machine tests.
  @spec drive_clone(String.t(), :running | :stopped, Marshall.Accounts.User.t()) :: :ok
  defp drive_clone(id, power, _owner) do
    Fixture.advance(id)
    Fixture.prepare(id)

    if power == :running do
      Fixture.settle_source(id, :stopped)
      Fixture.advance(id)
    end

    Fixture.capture(id)

    if power == :running do
      Fixture.settle_source(id, :running)
      Fixture.advance(id)
    end

    Fixture.effect(id, :copy, {:dataset_guid, "102"})
    Fixture.advance(id)
    Fixture.effect(id, :adopt, :empty)
    Fixture.advance(id)
    request = Fixture.request(id)
    assert request.published_at
    [operation] = Ledger.read!(Operation, id: request.destination_operation_id)
    assert operation.kind == if(power == :running, do: :start, else: :stop)
    [destination] = Ledger.read!(VirtualMachine, id: request.destination_vm_id)
    Fixture.settle(destination, operation, power)
    Fixture.advance(id)
    Fixture.effect(id, :revoke, :empty)
    Fixture.advance(id)
    Fixture.effect(id, :prune, :empty, :source)
    Fixture.advance(id)
    assert Fixture.request(id).phase == :complete
    :ok
  end

  @spec rotated_image(String.t()) :: Marshall.Compute.Image.t()
  defp rotated_image(existing) do
    content = "rotated kernel " <> Ash.UUID.generate()

    artifact = %{
      "bytes" => byte_size(content),
      "sha256" => :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    }

    {:ok, image} =
      Marshall.Compute.Images.register(
        Map.put(image_manifest(), "kernel", artifact),
        "rotated-image"
      )

    assert image.id != existing
    image
  end

  @spec report_inventory_images(map(), String.t()) :: :ok
  defp report_inventory_images(fixture, image) do
    # Preserve the pool's current physical totals; rebuilding pools from the
    # enrollment-time report would silently shrink enlarged fixture budgets.
    [pool] = Ledger.read!(Marshall.Compute.StoragePool, id: fixture.pool.id)
    [pool_report] = fixture.report.pools

    pool_report = %{
      pool_report
      | total_bytes: pool.total_bytes,
        free_bytes: pool.free_bytes,
        storage: storage_observation(pool, pool.total_bytes, pool.free_bytes)
    }

    report = %{
      fixture.report
      | sequence: fixture.report.sequence + 9,
        sampled_at: Ledger.now(),
        inventory: Map.put(fixture.report.inventory, "images", [image]),
        pools: [pool_report]
    }

    assert {:ok, :ok} =
             Marshall.Compute.HostReports.ingest(fixture.host.id, fixture.epoch, report)

    :ok
  end

  @spec report_pool_capacity(map(), pos_integer()) :: :ok
  defp report_pool_capacity(fixture, budget) do
    [pool_report] = fixture.report.pools

    pool_report = %{
      pool_report
      | total_bytes: budget,
        free_bytes: budget,
        storage: storage_observation(fixture.pool, budget, budget)
    }

    report = %{
      fixture.report
      | sequence: fixture.report.sequence + 8,
        sampled_at: Ledger.now(),
        pools: [pool_report]
    }

    assert {:ok, :ok} =
             Marshall.Compute.HostReports.ingest(fixture.host.id, fixture.epoch, report)

    :ok
  end
end
