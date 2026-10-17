defmodule Marshall.Compute.ResizeCancellationTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  alias Marshall.Compute
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes, Reservation, Resize, VirtualMachine}

  @gib 1_073_741_824

  defp resize_args(vm, overrides \\ %{}) do
    Map.merge(
      %{
        vm_id: vm.id,
        expected_generation: current(vm).generation,
        idempotency_key: Ash.UUID.generate(),
        vcpu: 2,
        memory_bytes: 2 * @gib,
        disk_bytes: 3 * @gib
      },
      overrides
    )
  end

  defp provisioned(power) do
    host_fixture()
    owner = user()
    assert {:ok, vm} = Compute.provision(request(), actor: owner)
    assert {:ok, _} = ingest(vm, operation(vm), :running)

    if power == :stopped do
      assert {:ok, _} =
               Compute.lifecycle(
                 %{vm_id: vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
                 actor: owner
               )

      assert {:ok, _} = ingest(vm, operation(vm), :stopped)
    end

    {owner, current(vm)}
  end

  # @cc [owner:ghuntley,label:verification;recovery] resize-cancel-before-mutation-tested
  # Cancelling during the stop phase MUST restore the original holds, await the
  # stop, restart an originally running machine with its unchanged sizes and
  # finish as cancelled; an originally stopped machine finishes as cancelled on
  # the stop receipt. Cancellation MUST be refused once sizes are being applied
  # and while the stop's physical state is unconfirmed.
  test "a running machine's resize cancels through an unchanged restart" do
    {owner, vm} = provisioned(:running)
    original = Map.take(vm, [:vcpu, :memory_bytes, :disk_bytes])
    assert {:ok, resize} = Compute.resize(resize_args(vm), actor: owner)
    held = reservation(vm)
    assert held.pending_disk_bytes == @gib
    assert held.vcpu == 2

    assert {:ok, cancelling} =
             Compute.cancel_resize(%{vm_id: vm.id, request_id: resize.id}, actor: owner)

    assert cancelling.phase == :cancelling
    assert cancelling.cancelled_at != nil
    restored = reservation(vm)
    assert restored.pending_disk_bytes == 0
    assert restored.vcpu == original.vcpu
    assert restored.compute_held
    # Idempotent while cancelling; retry re-issues the stop if needed.
    assert {:ok, %{phase: :cancelling}} =
             Compute.cancel_resize(%{vm_id: vm.id, request_id: resize.id}, actor: owner)

    assert {:ok, _} = ingest(vm, operation(vm), :stopped)
    restarting = Resize.active(vm.id)
    assert restarting.phase == :restarting
    assert operation(vm).kind == :start
    assert {:ok, _} = ingest(vm, operation(vm), :running)
    assert Resize.active(vm.id) == nil
    [finished] = Ledger.read!(Marshall.Compute.ResizeRequest, id: resize.id)
    assert finished.phase == :cancelled and finished.finished_at != nil
    assert Map.take(current(vm), [:vcpu, :memory_bytes, :disk_bytes]) == original
    assert current(vm).observed_state == :running
    assert reservation(vm).compute_held
  end

  test "a stopped machine's resize cancels on the stop receipt and stays stopped" do
    {owner, vm} = provisioned(:stopped)
    assert {:ok, resize} = Compute.resize(resize_args(vm), actor: owner)

    assert {:ok, %{phase: :cancelling}} =
             Compute.cancel_resize(%{vm_id: vm.id, request_id: resize.id}, actor: owner)

    assert {:ok, _} = ingest(vm, operation(vm), :stopped)
    assert Resize.active(vm.id) == nil
    [finished] = Ledger.read!(Marshall.Compute.ResizeRequest, id: resize.id)
    assert finished.phase == :cancelled
    refute reservation(vm).compute_held
    assert reservation(vm).pending_disk_bytes == 0
    assert current(vm).desired_state == :stopped
  end

  test "cancellation is refused once sizes are applied" do
    {owner, vm} = provisioned(:running)
    assert {:ok, resize} = Compute.resize(resize_args(vm), actor: owner)
    assert {:ok, _} = ingest(vm, operation(vm), :stopped)
    assert Resize.active(vm.id).phase == :resizing

    assert {:error, %{errors: [%{reason: :resize_not_cancellable}]}} =
             Compute.cancel_resize(%{vm_id: vm.id, request_id: resize.id}, actor: owner)
  end

  test "cancellation is refused while the stop's physical state is unconfirmed" do
    {owner, vm} = provisioned(:running)
    assert {:ok, resize} = Compute.resize(resize_args(vm), actor: owner)

    assert {:ok, _} =
             ingest(vm, operation(vm), :unknown, %{compute_empty: false, reason: :unknown})

    assert Resize.active(vm.id).failure == "physical_state_unconfirmed"

    assert {:error, %{errors: [%{reason: :resize_not_cancellable}]}} =
             Compute.cancel_resize(%{vm_id: vm.id, request_id: resize.id}, actor: owner)
  end

  # @cc [owner:ghuntley,label:verification;recovery] resize-stop-without-disk-recorded
  # A stop receipt that confirms the guest down without its disk MUST be
  # recorded as physical_state_unconfirmed with every hold retained, not
  # refused as an invalid outcome that aborts the host's exchange; a retry
  # re-issues the stop and the resize then proceeds.
  test "a stop confirmed without its disk is recorded for retry, not refused" do
    {owner, vm} = provisioned(:running)
    assert {:ok, resize} = Compute.resize(resize_args(vm), actor: owner)
    assert {:ok, _} = ingest(vm, operation(vm), :stopped, %{disk_present: false})
    request = Resize.active(vm.id)
    assert request.phase == :stopping
    assert request.failure == "physical_state_unconfirmed"
    assert reservation(vm).pending_disk_bytes == @gib

    assert {:ok, _} =
             Compute.retry_resize(
               %{
                 vm_id: vm.id,
                 request_id: resize.id,
                 expected_generation: current(vm).generation
               },
               actor: owner
             )

    assert {:ok, _} = ingest(vm, operation(vm), :stopped)
    assert Resize.active(vm.id).phase == :resizing
  end

  defp current(vm), do: hd(Ledger.read!(VirtualMachine, id: vm.id))

  defp operation(vm),
    do: hd(Ledger.read!(Operation, vm_id: vm.id, generation: current(vm).generation))

  defp reservation(vm), do: hd(Ledger.read!(Reservation, vm_id: vm.id))

  defp next_sequence(vm) do
    Ledger.read!(Marshall.Compute.PhysicalOutcome, vm_id: vm.id)
    |> Enum.map(& &1.sequence)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp ingest(vm, operation, state, extra \\ %{}) do
    event =
      Map.merge(
        %{
          id: Ash.UUID.generate(),
          vm_id: vm.id,
          placement_id: operation.placement_id,
          execution_epoch: operation.execution_epoch,
          operation_id: operation.id,
          generation: operation.generation,
          sequence: next_sequence(vm),
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

    Ledger.transaction(fn ->
      Ledger.lock!(Host, vm.host_id)
      Outcomes.ingest_locked!(vm.host_id, [event])
    end)
  end
end
