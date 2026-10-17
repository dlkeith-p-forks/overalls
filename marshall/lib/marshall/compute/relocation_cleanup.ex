defmodule Marshall.Compute.RelocationCleanup do
  @moduledoc "Source deletion obligations, leased delivery and retained physical receipts."
  alias Marshall.Compute.{
    CleanupRequest,
    Operation,
    PhysicalOutcome,
    Credentials,
    Ledger,
    Relocation,
    RelocationReadinessState,
    Reservation,
    SourcePermitRequest,
    TransferSlot,
    VirtualMachine
  }

  alias OverallsProtocol.RelocationCleanup, as: Wire

  # @cc [owner:ghuntley,label:recovery;capacity] cleanup-release-after-physical-receipt
  # advance_locked!/2 requires both host locks followed by the VM lock. Creating
  # cleanup intent requires exact destination readiness or a durable logical Delete
  # superseding the committed relocation. Thereafter the same
  # obligation remains retryable even if the destination later fails. Only a
  # retained key retirement receipt plus cleanup and its completed delete operation/outcome
  # releases source storage. Stream slots may already be released by independent
  # endpoint revocation receipts; final cleanup releases any still-held slots.
  # destination commitments, current authority and the logical VM remain intact.
  @spec advance_locked!(Relocation.t(), VirtualMachine.t()) :: :ok
  def advance_locked!(relocation, vm) do
    case Ledger.read!(CleanupRequest, id: relocation.id) do
      [] ->
        if RelocationReadinessState.ready?(relocation, vm) or
             (relocation.deletion_requested_at != nil and relocation.committed_at != nil and
                vm.desired_state == :deleted) do
          [import] = Ledger.read!(SourcePermitRequest, id: relocation.import_request_id)
          {:ok, source} = OverallsProtocol.RelocationSource.command(import.request)

          unless source.generation < 9_223_372_036_854_775_807,
            do: Ledger.rollback(:generation_exhausted)

          Ledger.create!(CleanupRequest, :record, %{
            id: relocation.id,
            source_host_id: relocation.source_host_id,
            descriptor: import.descriptor,
            generation: source.generation
          })
        end

      [%{completed_at: completed, operation_id: nil} = request] when not is_nil(completed) ->
        operation =
          Ledger.create!(Operation, :enqueue, %{
            vm_id: relocation.vm_id,
            placement_id: relocation.source_placement_id,
            execution_epoch: relocation.source_epoch,
            generation: request.generation + 1,
            kind: :delete,
            initiator: :relocation,
            relocation_id: relocation.id
          })

        Ledger.update!(request, :record_operation, %{operation_id: operation.id})

      [%{completed_at: completed} = request] when not is_nil(completed) ->
        if deletion_confirmed?(request) and request.key_requested_at == nil do
          Ledger.update!(request, :request_key_retirement, %{key_requested_at: Ledger.now()})
        end

        if deletion_confirmed?(request) and request.key_retired_at != nil do
          [source] = Ledger.read!(Reservation, placement_id: relocation.source_placement_id)
          Ledger.update!(source, :release_all, %{})

          for endpoint <- [:source_relocation_id, :destination_relocation_id] do
            [slot] = Ledger.read!(TransferSlot, [{endpoint, relocation.id}])

            if slot.released_at == nil,
              do: Ledger.update!(slot, :release, %{released_at: Ledger.now()})
          end

          if relocation.deletion_requested_at == nil,
            do: Ledger.update!(relocation, :complete, %{finished_at: Ledger.now()})
        end

      [_] ->
        :ok
    end

    :ok
  end

  # @cc [owner:ghuntley,label:security;recovery] source-delete-operation-exact-obligation
  # Only the recorded cleanup obligation may deliver/complete an operation for a
  # superseded source placement. It MUST be that relocation's exact successor
  # source delete generation after native cleanup receipt. It never changes VM
  # desired/observed destination state. Ordinary stale operations stay suppressed.
  @spec operation_allowed?(Operation.t()) :: boolean()
  def operation_allowed?(%{initiator: :relocation, kind: :delete} = operation) do
    with [request] <- Ledger.read!(CleanupRequest, id: operation.relocation_id),
         true <-
           request.completed_at != nil and request.operation_id == operation.id and
             operation.generation == request.generation + 1,
         {:ok, descriptor} <- OverallsProtocol.Relocation.descriptor(request.descriptor),
         true <-
           operation.vm_id == descriptor.vm_id and
             operation.placement_id == descriptor.source.placement_id and
             operation.execution_epoch == descriptor.source_epoch,
         do: true,
         else: (_ -> false)
  end

  def operation_allowed?(_), do: false

  defp deletion_confirmed?(request) do
    with [operation] <- Ledger.read!(Operation, id: request.operation_id),
         true <- operation_allowed?(operation) and operation.status == :completed,
         [outcome] <- Ledger.read!(PhysicalOutcome, id: operation.completion_outcome_id),
         {:ok, evidence} <- OverallsProtocol.Execution.outcome(outcome.observation),
         true <-
           outcome.host_id == request.source_host_id and evidence.operation_id == operation.id and
             evidence.vm_id == operation.vm_id and evidence.placement_id == operation.placement_id and
             evidence.execution_epoch == operation.execution_epoch and
             evidence.generation == operation.generation and
             evidence.state == :deleted and evidence.compute_empty and not evidence.disk_present and
             evidence.cleanup_complete,
         do: true,
         else: (_ -> false)
  end

  # @cc [owner:ghuntley,label:security;recovery] cleanup-authenticated-source-receipt
  # Exchanges MUST authenticate and fence the source session before VM locks.
  # Only the exact offered immutable request can complete; duplicates are
  # idempotent. Receipts only record evidence and enqueue reconciliation, never
  # release reservations while the other endpoint's host lock is absent.
  @spec exchange(String.t(), Wire.exchange()) :: {:ok, map()} | {:error, term()}
  def exchange(token, message) do
    Credentials.with_host(token, fn host ->
      unless host.connection_session_id == message.session_id and
               host.connection_epoch == message.epoch,
             do: Ledger.rollback(:stale_connection)

      accepted = Enum.map(Enum.sort_by(message.results, & &1.id), &accept!(host.id, &1))

      commands =
        Ledger.read!(CleanupRequest, source_host_id: host.id, completed_at: [is_nil: true])
        |> Enum.sort_by(& &1.id)
        |> Enum.take(16)
        |> Enum.flat_map(&command!/1)

      %{
        "version" => 4,
        "host_id" => host.id,
        "session_id" => message.session_id,
        "epoch" => host.connection_epoch,
        "commands" => commands,
        "acknowledgements" => accepted
      }
    end)
  end

  defp accept!(host, result) do
    with [%{source_host_id: ^host} = request] <- Ledger.read!(CleanupRequest, id: result.id),
         [relocation] <- Ledger.read!(Relocation, id: request.id) do
      Ledger.lock_history!(VirtualMachine, relocation.vm_id)
      [request] = Ledger.read!(CleanupRequest, id: request.id)

      unless request.offered_at != nil and request.generation == result.generation and
               request.descriptor ==
                 OverallsProtocol.Relocation.encode_descriptor(result.descriptor),
             do: Ledger.rollback(:invalid_outcome)

      if request.completed_at == nil do
        Ledger.update!(request, :complete, %{completed_at: Ledger.now()})
        Ledger.update!(relocation, :schedule, %{})
      end

      request.id
    else
      _ -> Ledger.rollback(:invalid_outcome)
    end
  end

  defp command!(request) do
    [relocation] = Ledger.read!(Relocation, id: request.id)
    Ledger.lock!(VirtualMachine, relocation.vm_id)
    [request] = Ledger.read!(CleanupRequest, id: request.id)

    if request.completed_at == nil and relocation.finished_at == nil do
      if request.offered_at == nil,
        do: Ledger.update!(request, :offer, %{offered_at: Ledger.now()})

      wire = %{
        "id" => request.id,
        "descriptor" => request.descriptor,
        "generation" => request.generation,
        "expires_at" => DateTime.to_unix(Ledger.now()) + 180
      }

      unless match?({:ok, _}, Wire.command(wire)), do: Ledger.rollback(:reconciliation_required)
      [wire]
    else
      []
    end
  end
end
