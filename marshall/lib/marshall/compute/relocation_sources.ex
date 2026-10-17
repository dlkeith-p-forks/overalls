defmodule Marshall.Compute.RelocationSources do
  @moduledoc "Source lease outbox and native snapshot replies under authenticated host authority."
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    Credentials,
    Ledger,
    NetworkAddress,
    Relocation,
    Reservation,
    SourcePermitRequest,
    TransferSlot,
    VirtualMachine,
    WorkloadPlacement
  }

  alias OverallsProtocol.RelocationSource, as: Wire
  require Ash.Query
  require Marshall.Events
  @maximum 9_223_372_036_854_775_807

  # @cc [owner:ghuntley,label:security;concurrency] source-exchange-authenticated-history
  # Exchanges MUST fence the current source host session before any request or
  # result mutation. Replies MUST match a retained immutable request and native
  # descriptor lineage; duplicates are idempotent and conflicting batches roll
  # back. Host locks precede VM locks. Replies are facts, never destination import
  # evidence, physical stop or permission to release commitments.
  @spec exchange(String.t(), Wire.exchange()) :: {:ok, map()} | {:error, term()}
  def exchange(token, message) do
    result =
      Credentials.with_host(token, fn host ->
        unless host.connection_session_id == message.session_id and
                 host.connection_epoch == message.epoch,
               do: Ledger.rollback(:stale_connection)

        results = Enum.map(Enum.sort_by(message.results, & &1.id), &accept!(host.id, &1))

        commands =
          Relocation
          |> Ash.Query.filter(
            source_host_id == ^host.id and is_nil(finished_at) and
              is_nil(cancellation_requested_at) and
              not is_nil(destination_public_key)
          )
          |> Ash.Query.sort(vm_id: :asc)
          |> Ash.Query.limit(16)
          |> Ash.read!(actor: SystemActor.compute())
          |> Enum.flat_map(&prepare_request!/1)

        response = %{
          "version" => 4,
          "host_id" => host.id,
          "session_id" => message.session_id,
          "epoch" => host.connection_epoch,
          "commands" => commands,
          "acknowledgements" => Enum.map(results, &elem(&1, 0))
        }

        {response, recorded(results), host.id}
      end)

    case result do
      {:ok, {response, events, host_id}} ->
        unless Marshall.Repo.in_transaction?() do
          Enum.each(events, fn {relocation_id, vm_id} ->
            Marshall.Events.emit("relocation.source_recorded",
              host_id: host_id,
              relocation_id: relocation_id,
              vm_id: vm_id
            )
          end)
        end

        {:ok, response}

      {:error, reason} when is_atom(reason) and reason != :unauthorized ->
        unless Marshall.Repo.in_transaction?(),
          do: Marshall.Events.emit("relocation.source_refused", reason: reason)

        {:error, reason}

      other ->
        other
    end
  end

  defp recorded(results) do
    Enum.flat_map(results, fn
      {_id, :replay} -> []
      {_id, {:recorded, relocation_id, vm_id}} -> [{relocation_id, vm_id}]
    end)
  end

  defp accept!(host, result) do
    with [request] <- Ledger.read!(SourcePermitRequest, id: result.id),
         true <- request.source_host_id == host,
         {:ok, command} <- validated(request),
         true <- Wire.matches?(command, result),
         [relocation] <- Ledger.read!(Relocation, id: request.relocation_id) do
      Ledger.lock_history!(VirtualMachine, relocation.vm_id)

      unless Map.delete(command.intent, :workload) == endpoint_scope(relocation) and
               command.public_key == relocation.destination_public_key,
             do: Ledger.rollback(:invalid_outcome)

      encoded = OverallsProtocol.Relocation.encode_descriptor(result.descriptor)
      previous = latest_result(relocation.id)

      if (request.descriptor != nil and request.descriptor != encoded) or
           (previous != nil and previous.descriptor != encoded),
         do: Ledger.rollback(:outcome_conflict)

      event =
        if request.descriptor == nil do
          Ledger.update!(request, :record_result, %{descriptor: encoded})
          {:recorded, relocation.id, relocation.vm_id}
        else
          :replay
        end

      {request.id, event}
    else
      _ -> Ledger.rollback(:invalid_outcome)
    end
  end

  # @cc [owner:ghuntley,label:capacity;recovery] stopped-source-request-retains-reservations
  # A source request asks for the one full stream of a physically stopped disk
  # (ADR-0155). Originally stopped workloads MUST have unchanged stopped intent
  # and observation; originally running workloads MUST have the recorded
  # physical relocation stop; connectivity alone MUST NOT authorize a snapshot.
  # Both disk reservations and transfer slots MUST be held; requests MUST NOT
  # require or acquire compute or temporary headroom. Expiry MUST use the
  # database clock and a new immutable revision; retries MUST reuse the original
  # expiry and pin a previously returned snapshot GUID. Creating requests MUST
  # NOT stop the source, change current placement or release capacity.
  # Cancellation MUST suppress new offers/renewals while retaining late physical facts.
  defp prepare_request!(relocation) do
    vm = Ledger.lock!(VirtualMachine, relocation.vm_id)
    now = Ledger.now() |> DateTime.to_unix()
    [relocation] = Ledger.read!(Relocation, id: relocation.id)

    if relocation.finished_at == nil and relocation.cancellation_requested_at == nil and vm != nil and
         vm.archived_at == nil and
         vm.current_placement_id == relocation.source_placement_id and
         vm.execution_epoch == relocation.source_epoch and stopped?(relocation, vm) and
         held?(relocation) and not final_received?(relocation.id) do
      last = latest_request(relocation.id)
      [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)

      intent =
        Map.put(
          endpoint_scope(relocation),
          :workload,
          vm
          |> Map.take([:image_id, :architecture, :profile, :vcpu, :memory_bytes, :disk_bytes])
          |> Map.put(:slot, address.slot)
        )

      if last do
        with {:ok, previous} <- validated(last),
             true <-
               previous.intent == intent and
                 previous.public_key == relocation.destination_public_key,
             do: :ok,
             else: (_ -> Ledger.rollback(:reconciliation_required))
      end

      cond do
        last != nil and last.request["generation"] != vm.generation ->
          []

        last != nil and last.request["expires_at"] > now + 90 ->
          if last.descriptor == nil, do: [last.request], else: []

        true ->
          revision = if last, do: last.revision + 1, else: 1
          if revision > @maximum, do: Ledger.rollback(:reconciliation_required)
          previous = latest_result(relocation.id)

          command = %{
            id: Ash.UUID.generate(),
            intent: intent,
            generation: vm.generation,
            public_key: relocation.destination_public_key,
            revision: revision,
            expires_at: now + 180,
            to_guid: if(previous, do: previous.descriptor["stream"]["to_guid"])
          }

          wire = Wire.encode_command(command)

          unless match?({:ok, ^command}, Wire.command(wire)),
            do: Ledger.rollback(:reconciliation_required)

          if last, do: Ledger.update!(last, :supersede, %{})
          if relocation.phase != :copying, do: Ledger.update!(relocation, :begin_copy, %{})

          Ledger.create!(SourcePermitRequest, :enqueue, %{
            id: command.id,
            relocation_id: relocation.id,
            source_host_id: relocation.source_host_id,
            revision: revision,
            request: wire
          })

          [wire]
      end
    else
      []
    end
  end

  # The source disk may be snapshotted only while physically stopped: an
  # originally stopped workload that stayed stopped, or the recorded relocation stop.
  defp stopped?(relocation, %{desired_state: :stopped, observed_state: :stopped} = vm),
    do:
      relocation.original_state == :stopped or
        Marshall.Compute.RelocationCoordinator.stop_confirmed?(relocation, vm)

  defp stopped?(_, _), do: false

  defp held?(relocation) do
    Enum.all?(
      [relocation.source_placement_id, relocation.destination_placement_id],
      &match?([%{disk_held: true}], Ledger.read!(Reservation, placement_id: &1))
    ) and
      match?(
        [%{released_at: nil}],
        Ledger.read!(TransferSlot, source_relocation_id: relocation.id)
      ) and
      match?(
        [%{released_at: nil}],
        Ledger.read!(TransferSlot, destination_relocation_id: relocation.id)
      )
  end

  defp endpoint(placement),
    do: %{placement_id: placement.id, host_id: placement.host_id, pool_id: placement.pool_id}

  defp endpoint_scope(relocation) do
    [source] = Ledger.read!(WorkloadPlacement, id: relocation.source_placement_id)
    [destination] = Ledger.read!(WorkloadPlacement, id: relocation.destination_placement_id)

    %{
      relocation_id: relocation.id,
      vm_id: relocation.vm_id,
      source: endpoint(source),
      destination: endpoint(destination),
      source_epoch: relocation.source_epoch,
      destination_epoch: relocation.destination_epoch
    }
  end

  defp latest_request(id) do
    SourcePermitRequest
    |> Ash.Query.filter(relocation_id == ^id)
    |> Ash.Query.sort(revision: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: SystemActor.compute())
  end

  defp latest_result(id) do
    SourcePermitRequest
    |> Ash.Query.filter(relocation_id == ^id and not is_nil(descriptor))
    |> Ash.Query.sort(revision: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: SystemActor.compute())
  end

  defp final_received?(id) do
    SourcePermitRequest
    |> Ash.Query.filter(relocation_id == ^id and not is_nil(destination_dataset_guid))
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: SystemActor.compute())
    |> is_nil()
    |> Kernel.not()
  end

  defp validated(record) do
    with {:ok, command} <- Wire.command(record.request),
         true <-
           command.id == record.id and command.intent.relocation_id == record.relocation_id and
             command.intent.source.host_id == record.source_host_id and
             command.revision == record.revision,
         do: {:ok, command},
         else: (_ -> :error)
  end
end
