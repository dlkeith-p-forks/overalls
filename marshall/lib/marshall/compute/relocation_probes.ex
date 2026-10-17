defmodule Marshall.Compute.RelocationProbes do
  @moduledoc "Authenticated probe outbox; lease installation and connectivity remain separate facts."
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    Credentials,
    Ledger,
    NetworkAddress,
    ProbeRequest,
    Relocation,
    Reservation,
    TransferSlot,
    VirtualMachine,
    WorkloadPlacement
  }

  alias OverallsProtocol.RelocationProbe, as: Wire
  require Ash.Query

  # @cc [owner:ghuntley,label:security;concurrency] probe-exchange-fences-host-before-vm
  # Exchanges MUST authenticate the current host session before locking VM history
  # and accepting exact immutable request results. Duplicate results preserve the
  # first receipt timestamp, including after archive. Offers MUST require current
  # running source authority, both retained copies and transfer slots. Cancellation,
  # Delete, handoff or expiry MUST suppress offers without discarding late facts.
  @spec exchange(String.t(), Wire.exchange()) :: {:ok, map()} | {:error, term()}
  def exchange(token, message) do
    Credentials.with_host(token, fn host ->
      unless host.connection_session_id == message.session_id and
               host.connection_epoch == message.epoch,
             do: Ledger.rollback(:stale_connection)

      accepted = Enum.map(Enum.sort_by(message.results, & &1.id), &accept!(host.id, &1))

      commands =
        Relocation
        |> Ash.Query.filter(
          (source_host_id == ^host.id or destination_host_id == ^host.id) and
            is_nil(finished_at) and is_nil(cancellation_requested_at) and is_nil(committed_at) and
            original_state == :running and
            not is_nil(destination_public_key)
        )
        |> Ash.Query.sort(vm_id: :asc)
        |> Ash.Query.limit(16)
        |> Ash.read!(actor: SystemActor.compute())
        |> Enum.flat_map(&offer!(&1, host.id))

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

  # @cc [owner:ghuntley,label:security;recovery] preflight-proof-fresh-before-stop
  # ready_request/3 requires both host locks followed by the VM lock. It MUST
  # return only a completed destination probe issued within 30 database-clock
  # seconds, with at least ten seconds of lease remaining, matching current
  # execution/workload/key/pin and an acknowledged source grant of the same lease.
  # Receipt time alone MUST NOT refresh an old probe. The selected request must
  # be recorded atomically with any resulting stop operation.
  @spec ready_request(Relocation.t(), VirtualMachine.t(), DateTime.t()) :: ProbeRequest.t() | nil
  def ready_request(relocation, vm, now) do
    with true <- eligible?(relocation, vm),
         %ProbeRequest{applied_at: applied} = probe when not is_nil(applied) <-
           latest(relocation.id, :probe),
         true <- DateTime.diff(now, probe.inserted_at, :microsecond) in 0..30_000_000,
         true <-
           DateTime.compare(applied, now) != :gt and
             DateTime.compare(applied, probe.inserted_at) != :lt,
         {:ok, command} <- validated(probe),
         true <- command.expires_at >= DateTime.to_unix(now) + 10,
         true <- command.source_endpoint == relocation.source_endpoint,
         [address] <- Ledger.read!(NetworkAddress, vm_id: vm.id),
         intent =
           Map.put(
             scope(relocation),
             :workload,
             vm
             |> Map.take([:image_id, :architecture, :profile, :vcpu, :memory_bytes, :disk_bytes])
             |> Map.put(:slot, address.slot)
           ),
         true <- same?(probe, vm, intent, relocation.destination_public_key),
         [%ProbeRequest{applied_at: installed} = grant] when not is_nil(installed) <-
           Ledger.read!(ProbeRequest,
             relocation_id: relocation.id,
             phase: :grant,
             revision: probe.revision
           ),
         {:ok, source} <- validated(grant),
         true <- DateTime.compare(installed, probe.inserted_at) != :gt,
         true <-
           Map.drop(source, [:id, :phase, :source_endpoint]) ==
             Map.drop(command, [:id, :phase, :source_endpoint]) do
      probe
    else
      _ -> nil
    end
  end

  defp accept!(host, result) do
    with [record] <- Ledger.read!(ProbeRequest, id: result.id),
         true <- record.host_id == host,
         {:ok, command} <- validated(record),
         true <- Wire.matches?(command, result),
         [relocation] <- Ledger.read!(Relocation, id: record.relocation_id) do
      Ledger.lock_history!(VirtualMachine, relocation.vm_id)

      unless Map.delete(command.intent, :workload) == scope(relocation) and
               command.public_key == relocation.destination_public_key and
               (command.phase == :grant or command.source_endpoint == relocation.source_endpoint),
             do: Ledger.rollback(:invalid_outcome)

      if record.applied_at == nil do
        Ledger.update!(record, :record_result, %{applied_at: Ledger.now()})

        # The stop accepts a probe only while it is fresh (ready_request/3), so a
        # first destination receipt must coordinate now, not on the next cron tick.
        if command.phase == :probe and relocation.finished_at == nil,
          do: Ledger.update!(relocation, :schedule, %{})
      end

      record.id
    else
      _ -> Ledger.rollback(:invalid_outcome)
    end
  end

  defp offer!(relocation, host) do
    vm = Ledger.lock!(VirtualMachine, relocation.vm_id)
    [relocation] = Ledger.read!(Relocation, id: relocation.id)

    if eligible?(relocation, vm) do
      [address] = Ledger.read!(NetworkAddress, vm_id: vm.id)

      intent =
        Map.put(
          scope(relocation),
          :workload,
          vm
          |> Map.take([:image_id, :architecture, :profile, :vcpu, :memory_bytes, :disk_bytes])
          |> Map.put(:slot, address.slot)
        )

      grant = latest(relocation.id, :grant)
      now = DateTime.to_unix(Ledger.now())

      cond do
        host == relocation.source_host_id ->
          offer_grant!(relocation, vm, intent, grant, now)

        host == relocation.destination_host_id and grant != nil and grant.applied_at != nil ->
          offer_probe!(relocation, vm, intent, grant, now)

        true ->
          []
      end
    else
      []
    end
  end

  defp offer_grant!(relocation, vm, intent, previous, now) do
    if previous && not same?(previous, vm, intent, relocation.destination_public_key),
      do: Ledger.rollback(:reconciliation_required)

    cond do
      previous != nil and previous.request["expires_at"] > now + 90 ->
        if previous.applied_at == nil, do: [previous.request], else: []

      true ->
        revision = if previous, do: previous.revision + 1, else: 1

        command = %{
          id: Ash.UUID.generate(),
          intent: intent,
          generation: vm.generation,
          phase: :grant,
          public_key: relocation.destination_public_key,
          challenge: if(previous, do: previous.request["challenge"], else: Ash.UUID.generate()),
          revision: revision,
          expires_at: now + 180,
          source_endpoint: nil
        }

        [enqueue!(command, relocation.source_host_id)]
    end
  end

  defp offer_probe!(relocation, vm, intent, grant, now) do
    if same?(grant, vm, intent, relocation.destination_public_key) and
         grant.request["expires_at"] > now + 30 do
      case Ledger.read!(ProbeRequest,
             relocation_id: relocation.id,
             revision: grant.revision,
             phase: :probe
           ) do
        [] ->
          {:ok, source} = validated(grant)

          [
            enqueue!(
              %{
                source
                | id: Ash.UUID.generate(),
                  phase: :probe,
                  source_endpoint: relocation.source_endpoint
              },
              relocation.destination_host_id
            )
          ]

        [%{applied_at: nil} = probe] ->
          [probe.request]

        [_] ->
          []
      end
    else
      []
    end
  end

  defp enqueue!(command, host) do
    wire = Wire.encode_command(command)

    unless match?({:ok, ^command}, Wire.command(wire)),
      do: Ledger.rollback(:reconciliation_required)

    Ledger.create!(ProbeRequest, :enqueue, %{
      id: command.id,
      relocation_id: command.intent.relocation_id,
      host_id: host,
      phase: command.phase,
      revision: command.revision,
      request: wire,
      expires_at: DateTime.from_unix!(command.expires_at),
      inserted_at: Ledger.now()
    })

    wire
  end

  defp eligible?(r, vm) do
    vm != nil and vm.archived_at == nil and r.finished_at == nil and r.committed_at == nil and
      r.cancellation_requested_at == nil and r.deletion_requested_at == nil and
      r.original_state == :running and
      r.source_stop_operation_id == nil and
      vm.desired_state == :running and vm.observed_state == :running and
      vm.current_placement_id == r.source_placement_id and vm.execution_epoch == r.source_epoch and
      Enum.all?([r.source_placement_id, r.destination_placement_id], fn placement ->
        match?(
          [%{disk_held: true, compute_held: true}],
          Ledger.read!(Reservation, placement_id: placement)
        )
      end) and
      match?([%{released_at: nil}], Ledger.read!(TransferSlot, source_relocation_id: r.id)) and
      match?([%{released_at: nil}], Ledger.read!(TransferSlot, destination_relocation_id: r.id))
  end

  defp same?(record, vm, intent, public) do
    case validated(record) do
      {:ok, command} ->
        command.intent == intent and command.generation == vm.generation and
          command.public_key == public

      _ ->
        false
    end
  end

  defp scope(r) do
    [source] = Ledger.read!(WorkloadPlacement, id: r.source_placement_id)
    [destination] = Ledger.read!(WorkloadPlacement, id: r.destination_placement_id)

    %{
      relocation_id: r.id,
      vm_id: r.vm_id,
      source_epoch: r.source_epoch,
      destination_epoch: r.destination_epoch,
      source: endpoint(source),
      destination: endpoint(destination)
    }
  end

  defp endpoint(p), do: %{placement_id: p.id, host_id: p.host_id, pool_id: p.pool_id}

  defp latest(id, phase) do
    ProbeRequest
    |> Ash.Query.filter(relocation_id == ^id and phase == ^phase)
    |> Ash.Query.sort(revision: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: SystemActor.compute())
  end

  defp validated(record) do
    with {:ok, command} <- Wire.command(record.request),
         endpoint =
           if(command.phase == :grant,
             do: command.intent.source,
             else: command.intent.destination
           ),
         true <-
           command.id == record.id and command.intent.relocation_id == record.relocation_id and
             endpoint.host_id == record.host_id and command.phase == record.phase and
             command.revision == record.revision and
             command.expires_at == DateTime.to_unix(record.expires_at),
         do: {:ok, command},
         else: (_ -> :error)
  end
end
