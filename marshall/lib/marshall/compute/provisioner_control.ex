defmodule Marshall.Compute.ProvisionerControl do
  @moduledoc "Authenticated, host-fenced control exchanges backed entirely by PostgreSQL."
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    Credentials,
    Host,
    HostReports,
    HostSession,
    Ledger,
    Operation,
    Outcomes,
    StoragePool,
    WorkloadPlacement
  }

  require Ash.Query
  require Marshall.Events

  @spec open_execution(String.t(), OverallsProtocol.Execution.session()) ::
          {:ok, map()} | {:error, term()}
  def open_execution(token, %{session_id: id, machine_id: machine}),
    do: open_session(token, id, machine)

  # @cc [owner:ghuntley,label:security] stream-identity-current-session
  # terminal_stream_identity/1 MUST authenticate the host credential and
  # return only the host's exact current execution session identity; stale or
  # rotated credentials MUST deny the stream upgrade.
  @spec terminal_stream_identity(String.t()) :: {:ok, map()} | {:error, term()}
  def terminal_stream_identity(token) do
    Credentials.with_host(token, fn host ->
      if is_binary(host.connection_session_id) do
        %{host_id: host.id, session_id: host.connection_session_id, epoch: host.connection_epoch}
      else
        Ledger.rollback(:stale_connection)
      end
    end)
  end

  # @cc [owner:ghuntley,label:security] control-session-nonce-fence
  # A consumed session nonce may be retried only while it is still the host's
  # current session with the same epoch. Old or foreign nonces MUST NOT
  # replace a successor, and v4 opens MUST match the enrolled physical machine ID.
  defp open_session(token, id, machine) do
    Credentials.with_host(token, fn host ->
      if host.machine_id != machine,
        do: Ledger.rollback(:machine_identity_mismatch)

      host =
        case Ledger.read!(HostSession, id: id) do
          [] ->
            epoch = host.connection_epoch + 1

            Ledger.create!(HostSession, :open, %{
              id: id,
              host_id: host.id,
              epoch: epoch
            })

            Ledger.update!(host, :connect, %{
              connection_session_id: id,
              connection_epoch: epoch,
              report_sequence: 0,
              reported_at: nil
            })

          [session] ->
            unless session.host_id == host.id and session.epoch == host.connection_epoch and
                     host.connection_session_id == id,
                   do: Ledger.rollback(:stale_connection)

            host
        end

      %{
        "version" => 4,
        "host_id" => host.id,
        "session_id" => id,
        "epoch" => host.connection_epoch,
        "report_interval_ms" => 1000,
        "pools" =>
          Enum.map(Ledger.read!(StoragePool, host_id: host.id), fn pool ->
            Map.new(StoragePool.descriptor(pool), fn {key, value} ->
              {Atom.to_string(key), value}
            end)
          end)
      }
    end)
  end

  # @cc [owner:ghuntley,label:concurrency] control-exchange-atomicity
  # The v4 exchange MUST authenticate the current session/epoch and commit its
  # physical outcomes, capacity report, receipts and drain confirmation together.
  # Response commands MUST remain bound to the operation's immutable placement,
  # the current VM placement/epoch/generation (or the exact recorded source cleanup
  # delete obligation for a superseded placement) and reserved
  # addresses; unreconcilable commands MUST abort the exchange.
  @spec exchange_execution(String.t(), OverallsProtocol.Execution.exchange()) ::
          {:ok, map()} | {:error, term()}
  # @cc [owner:ghuntley,label:recovery] outcome-log-after-commit
  # Outcome diagnostics MUST follow a successful outer transaction and MUST NOT
  # describe rolled-back or duplicate receipts as newly recorded outcomes.
  def exchange_execution(token, message) do
    result =
      Credentials.with_host(token, fn host ->
        unless host.connection_session_id == message.session_id and
                 host.connection_epoch == message.epoch,
               do: Ledger.rollback(:stale_connection)

        {accepted, events} = Outcomes.ingest_with_events_locked!(host.id, message.outcomes)

        events =
          if message.report,
            do:
              events ++
                HostReports.ingest_with_events_locked!(host, message.epoch, message.report),
            else: events

        acknowledge!(host.id, message.acknowledgements)

        confirmed =
          Marshall.Compute.Drains.confirm_locked!(Ledger.lock!(Host, host.id))

        cleanup_operations =
          Ledger.read!(Marshall.Compute.CleanupRequest,
            source_host_id: host.id,
            completed_at: [is_nil: false],
            operation_id: [is_nil: false],
            relocation: [finished_at: [is_nil: true]]
          )
          |> Enum.map(& &1.operation_id)

        commands =
          Operation
          |> Ash.Query.filter(
            placement.host_id == ^host.id and status in [:pending, :acknowledged] and
              ((vm.current_placement_id == placement_id and vm.execution_epoch == execution_epoch) or
                 id in ^cleanup_operations)
          )
          |> Ash.Query.sort(status: :desc, inserted_at: :asc, id: :asc)
          |> Ash.Query.limit(OverallsProtocol.max_commands())
          |> Ash.Query.load([:placement, vm: [:network_address]])
          |> Ash.read!(actor: SystemActor.compute())
          |> Enum.map(fn operation ->
            address = operation.vm.network_address

            unless address != nil and address.profile == operation.vm.profile,
              do: Ledger.rollback(:reconciliation_required)

            wire = command(operation)

            unless match?({:ok, _}, OverallsProtocol.Execution.command(wire)),
              do: Ledger.rollback(:reconciliation_required)

            wire
          end)

        response = %{
          "version" => 4,
          "host_id" => host.id,
          "session_id" => message.session_id,
          "epoch" => host.connection_epoch,
          "commands" => commands,
          "outcome_acknowledgements" => accepted
        }

        {response, events, confirmed, host.id}
      end)

    case result do
      {:ok, {response, events, confirmed, host_id}} ->
        # Nested transaction callers cannot establish the outer commit here.
        unless Marshall.Repo.in_transaction?() do
          Enum.each(events, fn
            %{state: _, vm_id: vm_id} = outcome ->
              Marshall.Events.emit("vm.physical_outcome",
                host_id: host_id,
                vm_id: vm_id,
                operation_id: outcome.operation_id,
                placement_id: outcome.placement_id,
                execution_epoch: outcome.execution_epoch,
                generation: outcome.generation,
                outcome_state: outcome.state,
                reason: outcome.reason
              )

            {:resize_phase, vm_id, phase} ->
              Marshall.Events.emit("vm.resize_phase", vm_id: vm_id, operation_status: phase)

            {:resize_finished, vm_id, operation_id} ->
              Marshall.Events.emit("vm.resize_finished", vm_id: vm_id, operation_id: operation_id)

            {:resize_failed, vm_id, reason} ->
              Marshall.Events.emit("vm.resize_failed", vm_id: vm_id, reason: reason)

            {:resize_cancelled, vm_id, request_id} ->
              Marshall.Events.emit("vm.resize_cancelled",
                vm_id: vm_id,
                resize_request_id: request_id
              )

            {:recovery_restarted, vm_id, operation_id} ->
              Marshall.Events.emit("vm.recovery_restarted",
                vm_id: vm_id,
                operation_id: operation_id
              )
          end)

          Enum.each(confirmed, fn drain ->
            Marshall.Events.emit("host.drain_confirmed",
              host_id: drain.host_id,
              drain_id: drain.id,
              operation_status: drain.status
            )
          end)
        end

        {:ok, response}

      error ->
        error
    end
  end

  # @cc [owner:ghuntley,label:recovery] control-receipt-is-not-completion
  # Every receipt ID MUST identify an operation belonging to the authenticated
  # placement host, including an archived VM or a superseded placement. A receipt
  # may change pending to acknowledged
  # but MUST NOT establish physical completion or release allocations.
  defp acknowledge!(_host_id, []), do: :ok

  defp acknowledge!(host_id, ids) do
    operations =
      Operation
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!(actor: SystemActor.compute())

    unless length(operations) == length(ids), do: Ledger.rollback(:invalid_acknowledgement)

    Enum.each(operations, fn operation ->
      # A deletion outcome in this same exchange may already have archived the VM.
      case Ledger.read!(WorkloadPlacement, id: operation.placement_id) do
        [%{host_id: ^host_id}] -> :ok
        _ -> Ledger.rollback(:invalid_acknowledgement)
      end

      if operation.status == :pending, do: Ledger.update!(operation, :acknowledge, %{})
    end)
  end

  defp command(operation) do
    vm = operation.vm

    unless (vm.generation == operation.generation and
              vm.current_placement_id == operation.placement_id and
              vm.execution_epoch == operation.execution_epoch) or
             Marshall.Compute.RelocationCleanup.operation_allowed?(operation),
           do: Ledger.rollback(:reconciliation_required)

    operation.command_snapshot
  end
end
