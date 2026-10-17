defmodule Marshall.Compute.RelocationReceives do
  @moduledoc "Authenticated destination receive requests and retained local GUID receipts."
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

  alias OverallsProtocol.{RelocationReceive, RelocationSource}
  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;concurrency] receive-exchange-fences-destination
  # Exchanges MUST lock/authenticate the current destination session before VM
  # locks and receipt mutations. Commands require a source-confirmed descriptor,
  # unexpired permit, unchanged source authority and retained endpoint holds/slots.
  # Results MUST match retained request/descriptor and one destination-local GUID
  # across revisions and stream phases. Conflicting batches roll back. Receipts
  # are historical staging facts, never activation, live lease or capacity release.
  # Cancellation MUST suppress new offers/renewals while retaining late physical facts.
  @spec exchange(String.t(), RelocationReceive.exchange()) :: {:ok, map()} | {:error, term()}
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
            destination_host_id == ^host.id and is_nil(finished_at) and
              is_nil(cancellation_requested_at) and
              not is_nil(destination_public_key)
          )
          |> Ash.Query.sort(vm_id: :asc)
          |> Ash.Query.limit(16)
          |> Ash.read!(actor: SystemActor.compute())
          |> Enum.flat_map(&commands!/1)

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
            Marshall.Events.emit("relocation.receive_recorded",
              host_id: host_id,
              relocation_id: relocation_id,
              vm_id: vm_id
            )
          end)
        end

        {:ok, response}

      {:error, reason} when is_atom(reason) and reason != :unauthorized ->
        unless Marshall.Repo.in_transaction?(),
          do: Marshall.Events.emit("relocation.receive_refused", reason: reason)

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
         [relocation] <- Ledger.read!(Relocation, id: request.relocation_id),
         true <- relocation.destination_host_id == host do
      Ledger.lock_history!(VirtualMachine, relocation.vm_id)
      [request] = Ledger.read!(SourcePermitRequest, id: result.id)

      unless valid_source?(request, relocation) and
               request.descriptor ==
                 OverallsProtocol.Relocation.encode_descriptor(result.descriptor),
             do: Ledger.rollback(:invalid_outcome)

      previous =
        SourcePermitRequest
        |> Ash.Query.filter(
          relocation_id == ^relocation.id and not is_nil(destination_dataset_guid)
        )
        |> Ash.read!(actor: SystemActor.compute())

      if Enum.any?(previous, &(&1.destination_dataset_guid != result.dataset_guid)),
        do: Ledger.rollback(:outcome_conflict)

      event =
        if request.destination_dataset_guid == nil do
          Ledger.update!(request, :record_receive, %{
            destination_dataset_guid: result.dataset_guid
          })

          Ledger.update!(relocation, :schedule, %{})
          {:recorded, relocation.id, relocation.vm_id}
        else
          :replay
        end

      {request.id, event}
    else
      _ -> Ledger.rollback(:invalid_outcome)
    end
  end

  defp commands!(relocation) do
    vm = Ledger.lock!(VirtualMachine, relocation.vm_id)
    [relocation] = Ledger.read!(Relocation, id: relocation.id)

    request =
      SourcePermitRequest
      |> Ash.Query.filter(relocation_id == ^relocation.id)
      |> Ash.Query.sort(revision: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(actor: SystemActor.compute())

    now = Ledger.now() |> DateTime.to_unix()

    if vm != nil and vm.archived_at == nil and relocation.finished_at == nil and
         relocation.cancellation_requested_at == nil and request != nil and
         request.destination_dataset_guid == nil and valid_source?(request, relocation) and
         request.request["expires_at"] > now + 15 and request.request["expires_at"] <= now + 300 and
         request.request["generation"] == vm.generation and
         vm.current_placement_id == relocation.source_placement_id and
         vm.execution_epoch == relocation.source_epoch and
         current_state?(relocation, vm) and current_workload?(request, vm) and
         held?(relocation) and final_received(relocation, vm) == nil do
      wire = %{
        "id" => request.id,
        "descriptor" => request.descriptor,
        "source_endpoint" => relocation.source_endpoint,
        "expires_at" => request.request["expires_at"]
      }

      unless match?({:ok, _}, RelocationReceive.command(wire)),
        do: Ledger.rollback(:reconciliation_required)

      [wire]
    else
      []
    end
  end

  # @cc [owner:ghuntley,label:recovery;security] final-receipt-import-prerequisite
  # Under destination host/VM serialization, final_received/2 MUST select a
  # source-confirmed full-stream descriptor, exact current stopped workload and
  # local GUID receipt with retained reservations/slots. An older received
  # revision remains usable when renewal raced its acknowledgement.
  @spec final_received(Relocation.t(), VirtualMachine.t() | nil) :: SourcePermitRequest.t() | nil
  def final_received(_, nil), do: nil

  def final_received(relocation, vm) do
    if vm.archived_at == nil and relocation.finished_at == nil and
         relocation.cancellation_requested_at == nil and
         vm.current_placement_id == relocation.source_placement_id and
         vm.execution_epoch == relocation.source_epoch do
      SourcePermitRequest
      |> Ash.Query.filter(
        relocation_id == ^relocation.id and not is_nil(destination_dataset_guid)
      )
      |> Ash.Query.sort(revision: :desc)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.find(fn request ->
        valid_source?(request, relocation) and current_workload?(request, vm) and
          request.request["generation"] == vm.generation and
          current_state?(relocation, vm) and held?(relocation)
      end)
    end
  end

  defp valid_source?(request, relocation) do
    with {:ok, command} <- RelocationSource.command(request.request),
         {:ok, descriptor} <- OverallsProtocol.Relocation.descriptor(request.descriptor),
         [source] <- Ledger.read!(WorkloadPlacement, id: relocation.source_placement_id),
         [destination] <- Ledger.read!(WorkloadPlacement, id: relocation.destination_placement_id),
         true <-
           command.id == request.id and command.revision == request.revision,
         true <- RelocationSource.matches?(command, %{id: request.id, descriptor: descriptor}),
         true <-
           descriptor.relocation_id == relocation.id and descriptor.vm_id == relocation.vm_id and
             descriptor.source.host_id == relocation.source_host_id and
             request.source_host_id == relocation.source_host_id and
             descriptor.source.placement_id == relocation.source_placement_id and
             descriptor.source.pool_id == source.pool_id and
             descriptor.destination.host_id == relocation.destination_host_id and
             descriptor.destination.placement_id == relocation.destination_placement_id and
             descriptor.destination.pool_id == destination.pool_id and
             descriptor.source_epoch == relocation.source_epoch and
             descriptor.destination_epoch == relocation.destination_epoch and
             command.public_key == relocation.destination_public_key,
         do: true,
         else: (_ -> false)
  end

  defp current_workload?(request, vm) do
    with {:ok, descriptor} <- OverallsProtocol.Relocation.descriptor(request.descriptor),
         [address] <- Ledger.read!(NetworkAddress, vm_id: vm.id) do
      descriptor.workload ==
        vm
        |> Map.take([:image_id, :architecture, :profile, :vcpu, :memory_bytes, :disk_bytes])
        |> Map.put(:slot, address.slot)
    else
      _ -> false
    end
  end

  # The only stream is a full copy of a physically stopped source: an originally
  # stopped workload that stayed stopped, or the recorded relocation stop.
  defp current_state?(relocation, %{desired_state: :stopped, observed_state: :stopped} = vm),
    do:
      relocation.original_state == :stopped or
        Marshall.Compute.RelocationCoordinator.stop_confirmed?(relocation, vm)

  defp current_state?(_, _), do: false

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
end
