defmodule Lilly.Transfer.SourceRuntime do
  @moduledoc "One authenticated transfer task alongside uninterrupted inventory and execution control."
  use GenServer
  require Lilly.Events
  alias Lilly.Control.Client
  alias Lilly.Transfer.WorkerDiagnostics
  alias Lilly.Transfer.Source

  @prepare_reasons [
    :source_request_unconfirmed,
    :source_authority_unconfirmed,
    :source_lease_expired,
    :source_lineage_unconfirmed,
    :source_command_unconfirmed,
    :source_claim_unconfirmed,
    :checkpoint_unconfirmed,
    :source_stream_busy,
    :source_snapshot_unconfirmed,
    :export_permit_unconfirmed
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    Process.flag(:sensitive, true)

    state = %{
      mode: Keyword.get(options, :mode, :prepare),
      config: Keyword.fetch!(options, :config),
      store: Keyword.fetch!(options, :store),
      session: Keyword.fetch!(options, :session),
      owner: Keyword.fetch!(options, :owner),
      task: nil,
      pending: %{},
      effect_failures: %{}
    }

    send(self(), :tick)
    {:ok, state}
  end

  # @cc [owner:ghuntley,label:recovery;security] source-runtime-bounded-retry
  # At most one source exchange/effect task may run at once, independently of
  # ordinary execution exchanges. Unacknowledged results MUST remain bounded and
  # retryable; restarts recover through durable requests and native journals.
  # Fenced sessions MUST stop issuing effects without releasing commitments.
  # Revocation mode MUST return only after durable permit fencing and sender
  # quiescence; retries reuse the permanent revocation tombstone.
  # Prune mode MUST additionally verify restored authority and native snapshot
  # absence before returning its independent snapshot cleanup receipt.
  # Probe mode MUST distinguish lease installation from connectivity results and
  # retain them until acknowledged without pausing ordinary control exchanges.
  # Destination cleanup mode MUST require terminal execution and key fences plus
  # confirmed local reclamation; source restoration is independent of this receipt.
  @impl true
  def handle_info(:tick, %{task: nil} = state) do
    task =
      Task.async(fn ->
        Process.flag(:sensitive, true)

        try do
          exchange(state)
        rescue
          _ -> {:error, :source_request_failed}
        catch
          _, _ -> {:error, :source_request_failed}
        end
      end)

    {:noreply, %{state | task: task}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, pending, failures} ->
        Process.send_after(self(), :tick, 1000)

        {:noreply,
         report_effect_failures(
           WorkerDiagnostics.recovered(%{state | pending: pending, task: nil}, :source),
           failures
         )}

      {:error, reason}
      when reason in [
             :stale_connection,
             :unauthorized,
             :unsupported_version,
             :outcome_conflict,
             :invalid_outcome
           ] ->
        event =
          case state.mode do
            :revoke -> :transfer_revocation_fenced
            :prune -> :transfer_snapshot_cleanup_fenced
            :destination_cleanup -> :transfer_destination_cleanup_fenced
            :prepare -> :transfer_source_fenced
            :probe -> :transfer_probe_fenced
          end

        send(state.owner, {event, self(), reason})
        {:noreply, %{state | task: nil}}

      failure ->
        Process.send_after(self(), :tick, 5000)
        {:noreply, WorkerDiagnostics.failed(%{state | task: nil}, :source, failure)}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state) do
    Process.send_after(self(), :tick, 5000)

    {:noreply,
     WorkerDiagnostics.failed(%{state | task: nil}, :source, {:error, :effect_task_exited})}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}
  @impl true
  def terminate(_, %{task: %Task{} = task}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok
  @impl true
  def format_status(status),
    do: Lilly.DiagnosticStatus.redact(status, %{pending_results: map_size(status.state.pending)})

  defp exchange(state) do
    with {:ok, response} <-
           control(state, Map.values(state.pending)) do
      pending = Map.drop(state.pending, response.acknowledgements)

      Enum.reduce_while(response.commands, {:ok, pending, %{}}, fn command,
                                                                   {:ok, pending, failures} ->
        cond do
          Map.has_key?(pending, command.id) ->
            {:cont, {:ok, pending, failures}}

          map_size(pending) == 16 ->
            {:halt, {:ok, pending, failures}}

          true ->
            case effect(state, command) do
              {:ok, result} ->
                {:cont, {:ok, Map.put(pending, command.id, result), failures}}

              {:error, reason} ->
                {:cont,
                 {:ok, pending, Map.put(failures, command.id, effect_failure(state.mode, reason))}}
            end
        end
      end)
    end
  end

  # @cc [owner:ghuntley,label:security;observability] source-effect-failure-diagnostics-deduped
  # Worker effect failures MUST report only a closed per-mode reason atom, operation and request ID;
  # commands, descriptors, endpoints and native output MUST NOT be logged.
  # Expected pool contention stays a quiet retry. Identical per-command
  # failures MUST be suppressed until that command succeeds, disappears or the
  # reason changes; ticking retries MUST NOT spam events. Cleanup-mode
  # rejections emit their own correlated module events and MUST NOT duplicate
  # them here.
  defp effect_failure(:prepare, :storage_busy), do: nil

  defp effect_failure(:prepare, reason) when reason in @prepare_reasons, do: reason
  defp effect_failure(:prepare, _), do: :source_request_unconfirmed
  defp effect_failure(:probe, _), do: :probe_unconfirmed
  defp effect_failure(:revoke, _), do: :source_revocation_unconfirmed
  defp effect_failure(_, _), do: nil

  defp report_effect_failures(state, failures) do
    :ok =
      Enum.each(failures, fn {id, reason} ->
        if state.effect_failures[id] != reason and reason != nil do
          case state.mode do
            :revoke ->
              Lilly.Events.emit("lilly.transfer_export_failed",
                reason: reason,
                request_id: id,
                operation: state.mode
              )

            _ ->
              Lilly.Events.emit("lilly.transfer_effect_failed",
                reason: reason,
                request_id: id,
                operation: state.mode
              )
          end
        end
      end)

    %{state | effect_failures: failures}
  end

  defp control(%{mode: :probe} = state, results),
    do: Client.exchange_relocation_probe(state.config.client, state.session, results)

  defp control(%{mode: :prepare} = state, results),
    do: Client.exchange_relocation_source(state.config.client, state.session, results)

  defp control(%{mode: :revoke} = state, results),
    do: Client.exchange_relocation_revocation(state.config.client, state.session, results)

  defp control(%{mode: :prune} = state, results),
    do: Client.exchange_relocation_snapshot_cleanup(state.config.client, state.session, results)

  defp control(%{mode: :destination_cleanup} = state, results),
    do:
      Client.exchange_relocation_destination_cleanup(state.config.client, state.session, results)

  defp effect(%{mode: :probe} = state, command),
    do: Lilly.Transfer.Probe.execute(state.config, state.store, command)

  defp effect(%{mode: :destination_cleanup} = state, command),
    do:
      Lilly.Transfer.DestinationCleanup.execute(
        state.config,
        OverallsProtocol.Relocation.encode_intent(command.intent),
        command.expires_at
      )

  defp effect(%{mode: :prune} = state, command),
    do: Lilly.Transfer.SourceSnapshotCleanup.execute(state.config, state.store, command)

  defp effect(%{mode: :prepare} = state, command),
    do: Source.execute(state.config, state.store, command)

  defp effect(%{mode: :revoke} = state, command),
    do:
      Lilly.Transfer.SourceRevocation.execute(
        state.config.transfer_state_dir,
        state.config.client.host_id,
        command
      )
end
