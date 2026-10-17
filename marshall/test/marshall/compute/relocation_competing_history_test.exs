defmodule Marshall.Compute.RelocationCompetingHistoryTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  import Marshall.ComputeFixtures
  alias Marshall.Compute

  alias Marshall.Compute.{
    Credentials,
    Host,
    HostReports,
    Ledger,
    NetworkAddress,
    Operation,
    ProvisionerControl,
    Relocation,
    RelocationCoordinator,
    RelocationDestinationRevocations,
    RelocationRevocations,
    Reservation,
    TransferSlot,
    VirtualMachine,
    WorkloadPlacement
  }

  @moduletag timeout: 180_000

  # @cc [owner:ghuntley,label:verification;capacity;recovery] competing-relocation-receipt-history
  # An independent stable workload MUST remain allocation-free on repeated real
  # relocation admission while the source slot is held. One endpoint receipt
  # MUST NOT release slots; both exact offered receipts MUST permit admission
  # after coordinator release even with restoration and disk cleanup pending.
  # Duplicate receipts and advances MUST preserve first release timestamps and
  # the competitor's complete allocation records. This is database authority
  # with synthetic outcomes, not evidence that native streams have ceased.
  property "competing relocation admission follows both endpoint stream receipts" do
    check all(
            source_first? <- boolean(),
            wrong_epoch? <- boolean(),
            repeats <- member_of([1, 2, 4]),
            history <-
              list_of(member_of([:failed_batch, :poll, :advance, :cancel]),
                min_length: 4,
                max_length: 12
              ),
            max_runs: 12
          ) do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)

      try do
        source = roomy_host()
        owner = user()
        incumbent = stopped_workload(owner)
        competitor = stopped_workload(owner)
        assert incumbent.host_id == source.host.id
        assert competitor.host_id == source.host.id
        destination = roomy_host()
        source_connection = connection(source.host)
        destination_connection = connection(destination.host)
        refresh(source, source_connection, 3)
        refresh(destination, destination_connection, 3)

        assert {:ok, original} =
                 Compute.relocate(
                   %{vm_id: incumbent.id, idempotency_key: Ash.UUID.generate()},
                   actor: owner
                 )

        assert original.source_host_id == source.host.id
        assert original.destination_host_id == destination.host.id
        assert length(slots(original)) == 2
        assert Enum.all?(slots(original), &is_nil(&1.released_at))
        original_slot_ids = Enum.map(slots(original), & &1.id) |> Enum.sort()
        competing_args = %{vm_id: competitor.id, idempotency_key: Ash.UUID.generate()}
        refuse(competing_args, owner, repeats)

        assert {:ok, cancelled} =
                 Compute.cancel_relocation(%{relocation_id: original.id}, actor: owner)

        assert cancelled.cancellation_requested_at

        source_receipt = %{
          id: original.id,
          placement_id: original.source_placement_id,
          execution_epoch: original.source_epoch
        }

        destination_receipt = %{
          id: original.id,
          placement_id: original.destination_placement_id,
          execution_epoch: original.destination_epoch
        }

        offer(:source, source_connection, source_receipt)
        offer(:destination, destination_connection, destination_receipt)

        for {side, channel, receipt} <- [
              {:source, source_connection, source_receipt},
              {:destination, destination_connection, destination_receipt}
            ] do
          wrong =
            if wrong_epoch?,
              do: %{receipt | execution_epoch: receipt.execution_epoch + 1},
              else: %{receipt | placement_id: Ash.UUID.generate()}

          before = inventory()
          assert {:error, :invalid_outcome} = exchange(side, channel, [wrong])
          assert inventory() == before
        end

        endpoints = [
          {:source, source_connection, source_receipt},
          {:destination, destination_connection, destination_receipt}
        ]

        receipt_history(
          [:failed_batch, :poll, :advance, :cancel] ++ history,
          endpoints,
          original,
          owner,
          false
        )

        [first, second] = if source_first?, do: endpoints, else: Enum.reverse(endpoints)
        {side, channel, receipt} = first
        assert {:ok, _} = exchange(side, channel, [receipt])
        advance(original, repeats)
        assert Enum.all?(slots(original), &is_nil(&1.released_at))
        refuse(competing_args, owner, repeats)

        receipt_history(
          [:failed_batch, :poll, :advance, :cancel] ++ history,
          [first],
          original,
          owner,
          true
        )

        {side, channel, receipt} = second
        assert {:ok, _} = exchange(side, channel, [receipt])
        assert Enum.all?(slots(original), &is_nil(&1.released_at))
        advance(original, repeats)
        released = slots(original)
        assert Enum.sort(Enum.map(released, & &1.id)) == original_slot_ids
        assert Enum.all?(released, &match?(%DateTime{}, &1.released_at))
        [pending] = Ledger.read!(Relocation, id: original.id)
        assert pending.source_restored_at == nil
        assert pending.destination_cleaned_at == nil
        assert pending.finished_at == nil

        refresh(source, source_connection, 4)
        refresh(destination, destination_connection, 4)
        assert {:ok, admitted} = Compute.relocate(competing_args, actor: owner)
        assert admitted.vm_id == competitor.id
        assert admitted.source_host_id == source.host.id
        assert admitted.destination_host_id == destination.host.id
        assert length(slots(admitted)) == 2
        assert Enum.all?(slots(admitted), &is_nil(&1.released_at))
        assert length(Ledger.read!(WorkloadPlacement, vm_id: competitor.id)) == 2
        assert length(Ledger.read!(Reservation, vm_id: competitor.id)) == 2
        allocations = inventory()

        for _ <- 1..repeats do
          for {side, channel, receipt} <- endpoints,
              do: assert({:ok, _} = exchange(side, channel, [receipt]))

          advance(original, 1)
          assert slots(original) == released
          assert inventory() == allocations
          assert {:ok, replay} = Compute.relocate(competing_args, actor: owner)
          assert replay.id == admitted.id
          assert inventory() == allocations
        end
      after
        :ok = Ecto.Adapters.SQL.Sandbox.checkin(Marshall.Repo)
      end
    end
  end

  @type receipt_event :: :failed_batch | :poll | :advance | :cancel

  # @cc [owner:ghuntley,label:verification;recovery] cancellation-receipt-prefix-authority
  # Failed mixed receipt batches MUST roll back even a valid receipt accepted
  # earlier in the batch. Polling, coordinator retries and cancellation replays
  # MUST NOT commit a cancelled relocation or release slots before both receipts.
  @spec receipt_history(
          [receipt_event()],
          [
            {:source | :destination, connection(), OverallsProtocol.RelocationRevocation.result()}
          ],
          Relocation.t(),
          Marshall.Accounts.User.t(),
          boolean()
        ) :: :ok
  defp receipt_history(events, endpoints, relocation, owner, duplicate?) do
    holds = Enum.sort_by(Ledger.read!(Reservation, vm_id: relocation.vm_id), & &1.id)

    for event <- events do
      for {side, channel, receipt} <- endpoints do
        before = inventory()

        case event do
          :failed_batch ->
            wrong = %{receipt | execution_epoch: receipt.execution_epoch + 1}
            assert {:error, :invalid_outcome} = exchange(side, channel, [receipt, wrong])
            assert inventory() == before

          :poll ->
            assert {:ok, _} = exchange(side, channel, if(duplicate?, do: [receipt], else: []))
            assert inventory() == before

          :advance ->
            advance(relocation, 1)

          :cancel ->
            assert {:ok, _} =
                     Compute.cancel_relocation(%{relocation_id: relocation.id}, actor: owner)
        end

        [retained] = Ledger.read!(Relocation, id: relocation.id)
        assert retained.committed_at == nil
        assert retained.activation_operation_id == nil
        assert retained.finished_at == nil
        assert Enum.all?(slots(relocation), &is_nil(&1.released_at))
        [vm] = Ledger.read!(VirtualMachine, id: relocation.vm_id)
        assert vm.current_placement_id == relocation.source_placement_id
        assert Enum.sort_by(Ledger.read!(Reservation, vm_id: relocation.vm_id), & &1.id) == holds
      end
    end

    :ok
  end

  @type connection :: {String.t(), %{session_id: String.t(), epoch: pos_integer(), results: []}}
  @type fixture :: %{
          host: Host.t(),
          pool: Compute.StoragePool.t(),
          epoch: pos_integer(),
          report: OverallsProtocol.report()
        }
  @type snapshot :: {
          [VirtualMachine.t()],
          [WorkloadPlacement.t()],
          [Reservation.t()],
          [NetworkAddress.t()],
          [Operation.t()],
          [TransferSlot.t()],
          [Relocation.t()]
        }

  @spec roomy_host() :: fixture()
  defp roomy_host do
    fixture = host_fixture()

    report = %{
      fixture.report
      | pools:
          Enum.map(fixture.report.pools, fn pool ->
            %{
              pool
              | total_bytes: 34_359_738_368,
                free_bytes: 34_359_738_368,
                storage: storage_observation(fixture.pool, 34_359_738_368, 34_359_738_368)
            }
          end)
    }

    assert {:ok, :ok} =
             HostReports.ingest(fixture.host.id, fixture.epoch, %{report | sequence: 2})

    %{fixture | report: report}
  end

  @spec stopped_workload(Marshall.Accounts.User.t()) :: VirtualMachine.t()
  defp stopped_workload(owner) do
    assert {:ok, vm} = Compute.provision(request(), actor: owner)
    [boot] = Ledger.read!(Operation, vm_id: vm.id)
    outcome(vm, boot, 1, :running)

    assert {:ok, stop} =
             Compute.lifecycle(
               %{vm_id: vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
               actor: owner
             )

    outcome(vm, stop, 2, :stopped)
    hd(Ledger.read!(VirtualMachine, id: vm.id))
  end

  @spec outcome(VirtualMachine.t(), Operation.t(), pos_integer(), :running | :stopped) :: :ok
  defp outcome(vm, operation, sequence, state) do
    event = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: sequence,
      state: state,
      compute_empty: state == :stopped,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    assert {:ok, parsed} =
             OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    assert {:ok, _} =
             Ledger.transaction(fn ->
               Ledger.lock!(Host, vm.host_id)
               Compute.Outcomes.ingest_locked!(vm.host_id, [parsed])
             end)

    :ok
  end

  @spec connection(Host.t()) :: connection()
  defp connection(host) do
    assert {:ok, credential} = Credentials.rotate(host.id, 3600)
    session = Ash.UUID.generate()

    assert {:ok, reply} =
             ProvisionerControl.open_execution(credential.token, %{
               session_id: session,
               machine_id: host.machine_id
             })

    {credential.token, %{session_id: session, epoch: reply["epoch"], results: []}}
  end

  @spec refresh(fixture(), connection(), pos_integer()) :: :ok
  defp refresh(fixture, {_, message}, sequence) do
    assert {:ok, :ok} =
             HostReports.ingest(fixture.host.id, message.epoch, %{
               fixture.report
               | sequence: sequence,
                 sampled_at: Ledger.now()
             })

    :ok
  end

  @spec offer(
          :source | :destination,
          connection(),
          OverallsProtocol.RelocationRevocation.result()
        ) ::
          :ok
  defp offer(side, channel, receipt) do
    assert {:ok, %{"commands" => [wire]}} = exchange(side, channel, [])

    parser =
      if side == :source,
        do: OverallsProtocol.RelocationRevocation,
        else: OverallsProtocol.RelocationDestinationRevocation

    assert {:ok, command} = parser.command(wire)
    assert Map.take(command, [:id, :placement_id, :execution_epoch]) == receipt
    :ok
  end

  @spec exchange(:source | :destination, connection(), [
          OverallsProtocol.RelocationRevocation.result()
        ]) :: {:ok, map()} | {:error, term()}
  defp exchange(side, {token, message}, results) do
    module = if side == :source, do: RelocationRevocations, else: RelocationDestinationRevocations
    module.exchange(token, %{message | results: results})
  end

  @spec slots(Relocation.t()) :: [TransferSlot.t()]
  defp slots(relocation) do
    for key <- [:source_relocation_id, :destination_relocation_id],
        slot <- Ledger.read!(TransferSlot, [{key, relocation.id}]),
        do: slot
  end

  @spec advance(Relocation.t(), pos_integer()) :: :ok
  defp advance(relocation, repeats) do
    for _ <- 1..repeats, do: assert({:ok, _} = RelocationCoordinator.advance(relocation.id))
    :ok
  end

  @spec refuse(
          %{vm_id: String.t(), idempotency_key: String.t()},
          Marshall.Accounts.User.t(),
          pos_integer()
        ) :: :ok
  defp refuse(arguments, owner, repeats) do
    before = inventory()

    for _ <- 1..repeats do
      assert {:error, error} = Compute.relocate(arguments, actor: owner)
      assert Exception.message(error) =~ "transfer_busy"
      assert inventory() == before
    end

    :ok
  end

  @spec inventory() :: snapshot()
  defp inventory do
    {
      Enum.sort_by(Ledger.read!(VirtualMachine), & &1.id),
      Enum.sort_by(Ledger.read!(WorkloadPlacement), & &1.id),
      Enum.sort_by(Ledger.read!(Reservation), & &1.id),
      Enum.sort_by(Ledger.read!(NetworkAddress), & &1.id),
      Enum.sort_by(Ledger.read!(Operation), & &1.id),
      Enum.sort_by(Ledger.read!(TransferSlot), & &1.id),
      Enum.sort_by(Ledger.read!(Relocation), & &1.id)
    }
  end
end
