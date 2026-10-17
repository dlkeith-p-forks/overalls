defmodule Marshall.Compute.CloneMatrixTest do
  @moduledoc """
  clone matrix classifications pin OSS/Customer retention, stopped-source power, grown-shape capture, image churn and post-publication ownership
  descriptor identity unification; the extended suite carries the retry and
  unconfirmed-copy slot stability contracts alongside.
  """
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures

  alias Marshall.Compute
  alias Marshall.CloneVerificationFixture, as: Fixture

  alias Marshall.Compute.{
    CloneEffect,
    CloneEffects,
    Image,
    Images,
    Ledger,
    Operation,
    Reservation,
    TransferSlot,
    VirtualMachine
  }

  setup do
    # Grown and custom shapes need room beyond the default fixture pool.
    pool_bytes = 34_359_738_368
    fixture = host_fixture()

    Ledger.update!(fixture.pool, :report, %{
      total_bytes: pool_bytes,
      free_bytes: pool_bytes,
      allocations: %{},
      reported_at: Ledger.now(),
      storage_observation: storage_observation(fixture.pool, pool_bytes, pool_bytes)
    })

    Map.merge(fixture, %{actor: user()})
  end

  # Each test provisions exactly one running source VM, mirroring the capacity
  # shape of the existing clone suite.
  defp provision_source(c, overrides \\ %{}) do
    {:ok, vm} = Compute.provision(request(overrides), actor: c.actor)
    [provision] = Ledger.read!(Operation, vm_id: vm.id)
    Fixture.settle(vm, provision, :running)
    vm
  end

  @shapes [:architecture, :image_id, :profile, :vcpu, :memory_bytes, :disk_bytes]

  # @cc [owner:ghuntley,label:verification;product] clone-captured-shape-retention
  # A clone's destination row and offered workload descriptor MUST equal the
  # source's durable image, profile and requested sizes at activation. Neither
  # the catalog nor omitted defaults may re-derive them for either clone side.
  test "an OSS source clones through the coordinator with its captured shape retained", c do
    vm = provision_source(c, %{profile: :oss, vcpu: 1})
    captured = shape(vm.id)

    {:ok, clone} =
      Compute.clone(%{vm_id: vm.id, idempotency_key: Ash.UUID.generate()}, actor: c.actor)

    complete_clone(clone, :running)
    [destination] = Ledger.read!(VirtualMachine, id: clone.destination_vm_id)
    assert destination.id != vm.id
    assert destination.owner_id == c.actor.id
    assert Map.take(destination, @shapes) == captured
    assert workload(clone) == descriptor(captured)
    assert destination.desired_state == :running and destination.observed_state == :running
    [source] = Ledger.read!(VirtualMachine, id: vm.id)
    assert Map.take(source, @shapes) == captured
  end

  # @cc [owner:ghuntley,label:verification;capacity] clone-stopped-source-power-invariant
  # Cloning an originally stopped source MUST NOT create a source start or stop
  # operation, and the published destination MUST settle only through its own
  # final stop command while retaining the source's custom shape.
  test "a customer source with a custom shape stays stopped across its clone", c do
    sizes = %{
      profile: :customer,
      vcpu: 1,
      memory_bytes: 1_073_741_824,
      disk_bytes: 3_221_225_472
    }

    vm = provision_source(c, sizes)

    {:ok, stop} =
      Compute.lifecycle(%{vm_id: vm.id, kind: :stop, idempotency_key: "stop-src"}, actor: c.actor)

    Fixture.settle(vm, stop, :stopped)
    captured = shape(vm.id)
    operations = Ledger.read!(Operation, vm_id: vm.id)
    assert [_, _] = operations

    {:ok, clone} =
      Compute.clone(%{vm_id: vm.id, idempotency_key: Ash.UUID.generate()}, actor: c.actor)

    complete_clone(clone, :stopped)
    request = Fixture.request(clone.id)
    assert request.original_power_state == :stopped
    assert request.source_operation_id == nil

    assert Enum.sort_by(Ledger.read!(Operation, vm_id: vm.id), & &1.id) ==
             Enum.sort_by(operations, & &1.id)

    [destination] = Ledger.read!(VirtualMachine, id: clone.destination_vm_id)
    assert Map.take(destination, @shapes) == captured
    assert workload(clone) == descriptor(captured)
    assert destination.desired_state == :stopped and destination.observed_state == :stopped
    [destination_operation] = Ledger.read!(Operation, vm_id: destination.id)
    assert destination_operation.kind == :stop
  end

  # @cc [owner:ghuntley,label:verification;capacity] clone-after-resize-grown-capture
  # After a completed ADR-0051 growth, a clone MUST capture the new sizes: the
  # destination row, workload descriptor and destination reservation MUST match
  # the grown shape and never the pre-resize one.
  test "a clone after resize captures the grown shape", c do
    vm = provision_source(c)
    grown_disk = 3_221_225_472
    grown_memory = 1_073_741_824

    {:ok, resize} =
      Compute.resize(
        %{
          vm_id: vm.id,
          expected_generation: 1,
          idempotency_key: Ash.UUID.generate(),
          vcpu: 1,
          memory_bytes: grown_memory,
          disk_bytes: grown_disk
        },
        actor: c.actor
      )

    Fixture.settle(vm, current_operation(vm), :stopped)

    settle_outcome(vm, current_operation(vm), :stopped, %{
      applied_sizes: resize.target_sizes
    })

    Fixture.settle(vm, current_operation(vm), :running)

    assert shape(vm.id) ==
             Map.take(vm, @shapes)
             |> Map.merge(%{vcpu: 1, memory_bytes: grown_memory, disk_bytes: grown_disk})

    {:ok, clone} =
      Compute.clone(%{vm_id: vm.id, idempotency_key: Ash.UUID.generate()}, actor: c.actor)

    complete_clone(clone, :running)
    captured = shape(vm.id)
    assert captured.vcpu == 1
    assert captured.memory_bytes == grown_memory
    assert captured.disk_bytes == grown_disk
    [destination] = Ledger.read!(VirtualMachine, id: clone.destination_vm_id)
    assert Map.take(destination, @shapes) == captured
    assert workload(clone) == descriptor(captured)
    [hold] = Ledger.read!(Reservation, vm_id: destination.id)
    assert hold.disk_held
    assert hold.disk_bytes >= grown_disk
  end

  # @cc [owner:ghuntley,label:verification;recovery] clone-survives-image-catalog-churn
  # Disabling or rotating an image MUST refuse fresh admission while leaving an
  # existing workload's clone activation, retained image and request replay
  # untouched. A non-inception clone stays independent of the configured
  # inception image; an existing VM reclassified by that configuration MUST
  # fail closed at activation without a destination, slot or copy.
  test "image disable and rotation never block an existing workload's clone", c do
    vm = provision_source(c)
    captured = shape(vm.id)
    [image] = Ledger.read!(Image, id: image_id())
    Ledger.update!(image, :configure, %{enabled: false})

    assert {:error, provision_error} = Compute.provision(request(), actor: c.actor)
    assert Exception.message(provision_error) =~ "image_unavailable"

    key = Ash.UUID.generate()

    {:ok, clone} =
      Compute.clone(%{vm_id: vm.id, idempotency_key: key}, actor: c.actor)

    # The queued identity replays even with the source image already disabled.
    assert {:ok, replay} =
             Compute.clone(%{vm_id: vm.id, idempotency_key: key}, actor: c.actor)

    assert replay.id == clone.id
    assert replay.destination_vm_id == clone.destination_vm_id
    rotated = rotated_image()
    assert rotated.id != image.id
    report_inventory(c, rotated.id)
    previous = Application.get_env(:marshall, :inception_image_id)
    Application.put_env(:marshall, :inception_image_id, rotated.id)
    complete_clone(clone, :running)
    Application.put_env(:marshall, :inception_image_id, previous)
    [destination] = Ledger.read!(VirtualMachine, id: clone.destination_vm_id)
    assert Map.take(destination, @shapes) == captured
    assert destination.image_id == image.id
    assert workload(clone)["image_id"] == image.id

    # An existing non-inception workload never consults the configured
    # inception image: this whole flow ran with it bound to the rotated image.
    # Reclassifying the workload's own image as the configured inception image
    # MUST fail closed at activation without a destination, slot or copy.
    on_exit(fn -> Application.put_env(:marshall, :inception_image_id, previous) end)
    Application.put_env(:marshall, :inception_image_id, image.id)

    refused_key = Ash.UUID.generate()

    {:ok, refused} =
      Compute.clone(%{vm_id: vm.id, idempotency_key: refused_key}, actor: c.actor)

    Fixture.advance(refused.id)
    current = Fixture.request(refused.id)
    assert current.phase == :failed
    assert current.active == false
    assert current.failure == "profile_image_mismatch"
    assert current.finished_at
    assert Ledger.read!(VirtualMachine, id: refused.destination_vm_id) == []
    assert Ledger.read!(TransferSlot, clone_request_id: refused.id) == []

    {:ok, refused_replay} =
      Compute.clone(%{vm_id: vm.id, idempotency_key: refused_key}, actor: c.actor)

    assert refused_replay.id == refused.id
    assert refused_replay.phase == :failed
  end

  # @cc [owner:ghuntley,label:verification;recovery] copy-unconfirmed-retry-retains-snapshot
  # A physically unconfirmed copy MUST keep the request active in :copying with
  # its captured snapshot, holds and slots. An explicit retry MUST clear only
  # the diagnostic and re-offer that same snapshot and intent; completion then
  # publishes once and closes retry eligibility.
  test "an unconfirmed copy retains the captured snapshot for explicit retry", c do
    vm = provision_source(c)

    {:ok, clone} =
      Compute.clone(%{vm_id: vm.id, idempotency_key: Ash.UUID.generate()}, actor: c.actor)

    Fixture.advance(clone.id)
    Fixture.prepare(clone.id)
    Fixture.settle_source(clone.id, :stopped)
    Fixture.advance(clone.id)
    assert Fixture.request(clone.id).phase == :capturing

    {:ok, credential} = Marshall.Compute.Credentials.rotate(c.host.id, 3600)
    session = Ash.UUID.generate()

    {:ok, opened} =
      Marshall.Compute.ProvisionerControl.open_execution(credential.token, %{
        session_id: session,
        machine_id: c.host.machine_id
      })

    message = %{session_id: session, epoch: opened["epoch"], results: []}

    assert {:ok, %{"commands" => capture_commands}} =
             CloneEffects.exchange(credential.token, message)

    offered_capture = Enum.find(capture_commands, &(&1["kind"] == "capture"))
    assert offered_capture

    # Capture completes only through an authenticated, intent-bound receipt.
    descriptor =
      Map.put(CloneEffects.intent(Fixture.request(clone.id)), "stream", %{
        "source_dataset_guid" => "100",
        "to_guid" => "101"
      })

    capture_receipt = %{
      "id" => offered_capture["id"],
      "kind" => "capture",
      "result" => %{"descriptor" => descriptor}
    }

    assert {:ok, %{"acknowledgements" => [capture_id]}} =
             CloneEffects.exchange(credential.token, %{message | results: [capture_receipt]})

    assert capture_id == offered_capture["id"]
    Fixture.advance(clone.id)
    Fixture.settle_source(clone.id, :running)
    Fixture.advance(clone.id)
    before = Fixture.request(clone.id)
    assert before.phase == :copying and before.snapshot != nil and before.active
    [copy] = Ledger.read!(CloneEffect, clone_request_id: clone.id, kind: :copy)
    assert copy.completed_at == nil
    holds = shape_holds(vm.id, clone.destination_vm_id)
    slots = Ledger.read!(TransferSlot, clone_request_id: clone.id)
    assert slots != []

    assert {:ok, %{"commands" => commands}} = CloneEffects.exchange(credential.token, message)
    offered = Enum.find(commands, &(&1["id"] == copy.id))
    assert offered

    uncertain = %{
      "id" => copy.id,
      "kind" => "copy",
      "result" => %{"error" => "unconfirmed", "reason" => "storage_busy"}
    }

    for _attempt <- 1..2 do
      assert {:ok, %{"acknowledgements" => [id]}} =
               CloneEffects.exchange(credential.token, %{message | results: [uncertain]})

      assert id == copy.id
      current = Fixture.request(clone.id)
      assert current.failure == "copy_storage_busy"
      assert current.phase == :copying and current.snapshot == before.snapshot
      assert current.published_at == nil and current.finished_at == nil
      assert shape_holds(vm.id, clone.destination_vm_id) == holds
      assert Ledger.read!(TransferSlot, clone_request_id: clone.id) == slots
      [pending] = Ledger.read!(CloneEffect, id: copy.id)
      assert pending.status == :offered and pending.result == nil
    end

    assert {:ok, retried} = Compute.retry_clone(%{request_id: clone.id}, actor: c.actor)
    assert retried.id == clone.id
    assert Fixture.request(clone.id).failure == nil

    assert {:ok, %{"commands" => retry_commands}} =
             CloneEffects.exchange(credential.token, message)

    reoffered = Enum.find(retry_commands, &(&1["id"] == copy.id))
    assert reoffered
    assert reoffered["descriptor"] == offered["descriptor"]
    assert reoffered["intent"] == offered["intent"]

    assert {:ok, _} =
             CloneEffects.exchange(credential.token, %{
               message
               | results: [%{uncertain | "result" => %{"dataset_guid" => "102"}}]
             })

    [completed] = Ledger.read!(CloneEffect, id: copy.id)
    assert completed.result == %{"dataset_guid" => "102"}
    publish_and_clean(clone, :running)
    current = Fixture.request(clone.id)
    assert current.destination_vm_id == clone.destination_vm_id
    assert sorted_slots_released(clone.id)

    [source_hold] = Ledger.read!(Reservation, vm_id: vm.id)
    assert source_hold.temporary_disk_bytes == 0
    [destination_hold] = Ledger.read!(Reservation, vm_id: clone.destination_vm_id)
    assert destination_hold.disk_held

    assert {:error, retry_error} = Compute.retry_clone(%{request_id: clone.id}, actor: c.actor)
    assert Exception.message(retry_error) =~ "clone_not_retryable"
  end

  # @cc [owner:ghuntley,label:verification;recovery] published-failure-closes-clone-controls
  # Once publication hands lifecycle authority to the ordinary VM model, a
  # terminal destination failure MUST close clone retry and cancellation
  # while retaining the captured snapshot, request and destination rows for
  # ordinary lifecycle recovery. No clone control may re-drive a published
  # request, and no later retry may substitute another snapshot.
  test "a failed published destination closes clone retry and cancellation", c do
    vm = provision_source(c)

    {:ok, clone} =
      Compute.clone(%{vm_id: vm.id, idempotency_key: Ash.UUID.generate()}, actor: c.actor)

    reach_copying(clone, :running)
    publish_only(clone)
    request = Fixture.request(clone.id)
    assert request.phase == :cleaning and request.published_at
    [operation] = Ledger.read!(Operation, id: request.destination_operation_id)
    [destination] = Ledger.read!(VirtualMachine, id: clone.destination_vm_id)
    Fixture.settle(destination, operation, :failed)

    Fixture.advance(clone.id)
    Fixture.effect(clone.id, :revoke, :empty)
    Fixture.advance(clone.id)
    Fixture.effect(clone.id, :prune, :empty, :source)
    Fixture.advance(clone.id)
    failed = Fixture.request(clone.id)
    assert failed.phase == :failed
    assert failed.failure == "destination_start_failed"
    assert failed.finished_at && failed.published_at
    assert failed.snapshot == request.snapshot
    assert failed.active == false
    assert sorted_slots_released(clone.id)

    assert {:error, retry_error} = Compute.retry_clone(%{request_id: clone.id}, actor: c.actor)
    assert Exception.message(retry_error) =~ "clone_not_retryable"

    assert {:error, cancel_error} = Compute.cancel_clone(%{request_id: clone.id}, actor: c.actor)
    assert Exception.message(cancel_error) =~ "clone_already_published"

    assert Ledger.read!(VirtualMachine, id: clone.destination_vm_id) != []

    assert Fixture.request(clone.id) |> Map.take([:phase, :failure, :finished_at]) ==
             Map.take(failed, [:phase, :failure, :finished_at])
  end

  # Drives the real coordinator from admission through confirmed capture using
  # the shared synthetic receipt fixture, leaving a pending copy effect.
  defp reach_copying(clone, captured_power) do
    Fixture.advance(clone.id)
    activated = Fixture.request(clone.id)
    assert {activated.phase, activated.failure} == {:preparing, nil}
    Fixture.prepare(clone.id)

    if captured_power == :running do
      Fixture.settle_source(clone.id, :stopped)
      Fixture.advance(clone.id)
    end

    Fixture.capture(clone.id)

    if captured_power == :running do
      Fixture.settle_source(clone.id, :running)
      Fixture.advance(clone.id)
    end
  end

  defp publish_only(clone) do
    Fixture.effect(clone.id, :copy, {:dataset_guid, "102"})
    Fixture.advance(clone.id)
    Fixture.effect(clone.id, :adopt, :empty)
    Fixture.advance(clone.id)
    assert Fixture.request(clone.id).published_at
    :ok
  end

  defp publish_and_clean(clone, captured_power) do
    publish_only(clone)
    request = Fixture.request(clone.id)
    [operation] = Ledger.read!(Operation, id: request.destination_operation_id)
    assert operation.kind == if(captured_power == :running, do: :start, else: :stop)
    [destination] = Ledger.read!(VirtualMachine, id: clone.destination_vm_id)
    Fixture.settle(destination, operation, captured_power)
    Fixture.advance(clone.id)
    Fixture.effect(clone.id, :revoke, :empty)
    Fixture.advance(clone.id)
    Fixture.effect(clone.id, :prune, :empty, :source)
    Fixture.advance(clone.id)
    assert Fixture.request(clone.id).phase == :complete
    :ok
  end

  defp complete_clone(clone, captured_power) do
    reach_copying(clone, captured_power)
    publish_and_clean(clone, captured_power)
  end

  defp current_operation(vm) do
    [current] = Ledger.read!(VirtualMachine, id: vm.id)
    hd(Ledger.read!(Operation, vm_id: vm.id, generation: current.generation))
  end

  defp shape(id) do
    [vm] = Ledger.read!(VirtualMachine, id: id)
    Map.take(vm, @shapes)
  end

  defp workload(clone) do
    clone.id
    |> Fixture.request()
    |> Map.fetch!(:specification)
    |> Map.fetch!("workload")
  end

  defp descriptor(shape) do
    shape
    |> Map.delete(:generation)
    |> Map.new(fn
      {key, value} when is_atom(value) -> {Atom.to_string(key), Atom.to_string(value)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  defp shape_holds(source_id, destination_id) do
    [source_id, destination_id]
    |> Enum.flat_map(&Ledger.read!(Reservation, vm_id: &1))
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&Map.take(&1, [:id, :vm_id, :disk_held, :compute_held, :temporary_disk_bytes]))
  end

  defp sorted_slots_released(clone_id) do
    slots = Ledger.read!(TransferSlot, clone_request_id: clone_id)
    slots != [] and Enum.all?(slots, &(not is_nil(&1.released_at)))
  end

  defp rotated_image do
    content = "rotated kernel " <> Ash.UUID.generate()
    manifest = image_manifest()

    artifact = %{
      "bytes" => byte_size(content),
      "sha256" => :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    }

    {:ok, image} = Images.register(Map.put(manifest, "kernel", artifact), "rotated-image")
    image
  end

  defp report_inventory(fixture, image) do
    report = %{
      fixture.report
      | sequence: fixture.report.sequence + 9,
        sampled_at: Ledger.now(),
        inventory: Map.put(fixture.report.inventory, "images", [image])
    }

    assert {:ok, :ok} =
             Marshall.Compute.HostReports.ingest(fixture.host.id, fixture.epoch, report)

    :ok
  end

  # The applied-sizes receipt is the ADR-0051 boundary the fixture's typed
  # settle/3 cannot express; physical outcomes remain synthetic here.
  defp settle_outcome(vm, operation, state, extra) do
    event =
      Map.merge(
        %{
          id: Ash.UUID.generate(),
          vm_id: vm.id,
          placement_id: operation.placement_id,
          execution_epoch: operation.execution_epoch,
          operation_id: operation.id,
          generation: operation.generation,
          sequence: operation.generation,
          state: state,
          compute_empty: state != :running,
          disk_present: true,
          cleanup_complete: false,
          reason: :none
        },
        extra
      )

    {:ok, event} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    {:ok, _} =
      Ledger.transaction(fn ->
        Ledger.lock!(Marshall.Compute.Host, vm.host_id)
        Marshall.Compute.Outcomes.ingest_locked!(vm.host_id, [event])
      end)

    :ok
  end
end
