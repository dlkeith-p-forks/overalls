defmodule Lilly.Transfer.ReceiveRuntime do
  @moduledoc "Independent control polling for one leased receive, adoption or readiness task."
  use GenServer
  require Lilly.Events
  alias Lilly.Control.Client
  alias Lilly.Transfer.Receiver
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc "Current attempt's transport progress only; nil when no receive attempt is active."
  @spec progress(GenServer.server()) :: map() | nil
  def progress(server), do: GenServer.call(server, :progress)

  @impl true
  def handle_call(:progress, _, state) do
    {:reply, progress_report(state), state}
  end

  defp progress_report(state) do
    if state.mode == :receive and not is_nil(state.active) and not state.fenced and
         mono() < state.active.deadline do
      %{
        request_id: state.active.command.id,
        attempt_id: state.active.attempt_id,
        attempt_sequence: state.active.attempt_sequence,
        bytes: state.active.bytes
      }
    end
  end

  # @cc [owner:ghuntley,label:recovery] receive-initial-retry-uses-monotonic-clock
  # A fresh worker MUST be immediately eligible for its first offered command.
  # Initial retry time MUST use the same monotonic clock as later comparisons;
  # zero is not a valid immediately-ready sentinel when that clock is negative.
  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    Process.flag(:sensitive, true)
    send(self(), :tick)

    {:ok,
     %{
       config: Keyword.fetch!(options, :config),
       mode: Keyword.get(options, :mode, :receive),
       store: Keyword.get(options, :store),
       session: Keyword.fetch!(options, :session),
       owner: Keyword.fetch!(options, :owner),
       exchange: nil,
       active: nil,
       pending: %{},
       last_failure: nil,
       retry_at: mono(),
       fenced: false
     }}
  end

  # @cc [owner:ghuntley,label:security;recovery] receive-runtime-live-control-during-stream
  # Cleanup mode fixes the source descriptor/generation, uses its own endpoint
  # and reports only confirmed physical deletion; control fencing stops its task.
  # Each worker runs at most one native effect and one control exchange. Import
  # mode uses the separate adoption exchange/effect and the same lease rules;
  # its local GUID must remain fixed across renewal. Activity locks exclude receive.
  # Readiness mode fixes activation generation, uses its own control endpoint and
  # bounded native probe; lease renewal MUST NOT restart the guest probe deadline.
  # Polling MUST continue during streaming so newer source permits can extend the
  # same descriptor's deadline. Expired/fenced authority stops the receive task;
  # no stop or error releases commitments. Receipts remain bounded and retryable.
  # A new request ID for the same stream may correlate its verified receipt, but
  # changed descriptor/pin MUST NOT extend an already running transfer.
  @impl true
  def handle_info(:tick, %{fenced: true} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 1000)

    state =
      if state.active && mono() >= state.active.deadline, do: expire_active(state), else: state

    if state.exchange do
      {:noreply, state}
    else
      config = state.config
      session = state.session
      results = Map.values(state.pending)
      mode = state.mode
      task = task(fn -> exchange(mode, config.client, session, results) end)
      {:noreply, %{state | exchange: task}}
    end
  end

  def handle_info({ref, result}, %{exchange: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | exchange: nil}

    case result do
      {:ok, response} ->
        state = %{state | pending: Map.drop(state.pending, response.acknowledgements)}
        {:noreply, commands(state, response.commands)}

      {:error, reason}
      when reason in [
             :unauthorized,
             :stale_connection,
             :unsupported_version,
             :outcome_conflict,
             :invalid_outcome
           ] ->
        kind =
          case state.mode do
            :cleanup -> :transfer_cleanup_fenced
            :readiness -> :transfer_readiness_fenced
            :import -> :transfer_import_fenced
            :receive -> :transfer_receive_fenced
          end

        send(state.owner, {kind, self(), reason})
        {:noreply, %{stop_active(state) | fenced: true}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, %{active: %{task: %Task{ref: ref}} = active} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(active.timer)
    state = %{state | active: nil, retry_at: mono() + 5000}

    case result do
      {:ok, guid} ->
        receipt = receipt(state.mode, active.command, guid)

        {:noreply,
         %{state | pending: Map.put(state.pending, receipt.id, receipt), last_failure: nil}}

      failure ->
        {:noreply, report_failure(state, failure)}
    end
  end

  # @cc [owner:ghuntley,label:protocol;capacity] receive-progress-cannot-change-authority
  # Counters MUST match the current receive task, be monotonic and arrive before
  # its lease expires. Fenced, old-task and decreasing updates MUST be ignored.
  # Coalesce one counter per active attempt; never accumulate an event history,
  # renew a lease, create a receipt or release capacity from these observations.
  def handle_info(
        {:lilly_transfer_progress, pid, count},
        %{mode: :receive, fenced: false, active: %{task: %Task{pid: pid}} = active} = state
      )
      when is_integer(count) and count in 0..9_223_372_036_854_775_807 do
    if mono() < active.deadline and count >= active.bytes,
      do: {:noreply, %{state | active: %{active | bytes: count}}},
      else: {:noreply, state}
  end

  def handle_info({:lease_expired, ref}, %{active: %{task: %Task{ref: ref}}} = state),
    do: {:noreply, if(mono() >= state.active.deadline, do: expire_active(state), else: state)}

  def handle_info({:lease_expired, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{exchange: %Task{ref: ref}} = state),
    do: {:noreply, %{state | exchange: nil}}

  def handle_info({:DOWN, ref, :process, _, _}, %{active: %{task: %Task{ref: ref}}} = state),
    do: {:noreply, state |> stop_active() |> report_failure({:error, :effect_task_exited})}

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    stop_active(state)
    if state.exchange, do: Task.shutdown(state.exchange, :brutal_kill)
    :ok
  end

  @impl true
  def format_status(status),
    do:
      Map.put(status, :state, %{
        receiving: status.state.active != nil,
        pending_receipts: map_size(status.state.pending)
      })

  defp commands(%{active: active} = state, commands) when not is_nil(active) do
    case Enum.find(
           commands,
           &(&1.descriptor == active.command.descriptor and
               Map.get(&1, :source_endpoint) == Map.get(active.command, :source_endpoint) and
               Map.get(&1, :dataset_guid) == Map.get(active.command, :dataset_guid) and
               Map.get(&1, :generation) == Map.get(active.command, :generation) and
               (Map.get(&1, :generation) == nil or &1.id == active.command.id))
         ) do
      nil ->
        state

      command ->
        case lease(command, active, System.system_time(:second), mono()) do
          {:ok, deadline} ->
            Process.cancel_timer(active.timer)

            timer =
              Process.send_after(
                self(),
                {:lease_expired, active.task.ref},
                max(deadline - mono(), 0)
              )

            %{state | active: %{active | command: command, deadline: deadline, timer: timer}}

          _ ->
            state
        end
    end
  end

  defp commands(state, commands) do
    if map_size(state.pending) < 16 and mono() >= state.retry_at do
      command = Enum.find(commands, &(not Map.has_key?(state.pending, &1.id)))

      with command when not is_nil(command) <- command,
           {:ok, deadline} <- lease(command, nil, System.system_time(:second), mono()),
           pool when not is_nil(pool) <-
             Enum.find(state.config.pools, &(&1.id == endpoint(command, state.mode).pool_id)) do
        config = state.config

        mode = state.mode
        store = state.store
        owner = self()

        task =
          task(fn ->
            if mode == :receive do
              Receiver.pull(
                config.transfer_state_dir,
                pool,
                OverallsProtocol.Relocation.encode_descriptor(command.descriptor),
                command.source_endpoint,
                86_400_000,
                config.transfer_bytes_per_second,
                owner
              )
            else
              effect(mode, config, pool, command, store)
            end
          end)

        timer = Process.send_after(self(), {:lease_expired, task.ref}, max(deadline - mono(), 0))

        %{
          state
          | active: %{
              command: command,
              deadline: deadline,
              task: task,
              timer: timer,
              attempt_id: Lilly.UUID.generate(),
              attempt_sequence: System.unique_integer([:positive, :monotonic]),
              bytes: 0
            }
        }
      else
        _ -> state
      end
    else
      state
    end
  end

  # @cc [owner:ghuntley,label:security] receive-lease-monotonic-bound
  # lease/4 MUST bound initial authority to at most 300 seconds. Only the same
  # descriptor and enrolled pin with nondecreasing signed expiry may renew it.
  # Unchanged expiry MUST NOT gain time after wall-clock rollback. Extension is
  # bounded by signed expiry growth and current remaining wall-clock validity.
  @spec lease(map(), map() | nil, integer(), integer()) :: {:ok, integer()} | {:error, atom()}
  def lease(command, previous, wall, monotonic) do
    remaining = command.expires_at - wall

    if remaining in 1..300 do
      case previous do
        nil ->
          {:ok, monotonic + remaining * 1000}

        %{command: old, deadline: deadline} ->
          if old.descriptor == command.descriptor and
               Map.get(old, :source_endpoint) == Map.get(command, :source_endpoint) and
               Map.get(old, :dataset_guid) == Map.get(command, :dataset_guid) and
               Map.get(old, :generation) == Map.get(command, :generation) and
               (Map.get(old, :generation) == nil or old.id == command.id) and
               command.expires_at >= old.expires_at and deadline > monotonic do
            {:ok,
             min(
               deadline + (command.expires_at - old.expires_at) * 1000,
               monotonic + remaining * 1000
             )}
          else
            {:error, :receive_lease_unconfirmed}
          end
      end
    else
      {:error, :receive_lease_unconfirmed}
    end
  end

  defp expire_active(state),
    do: state |> stop_active() |> report_failure({:error, :effect_lease_expired})

  defp stop_active(%{active: nil} = state), do: state

  defp stop_active(state) do
    Process.cancel_timer(state.active.timer)
    Task.shutdown(state.active.task, :brutal_kill)
    %{state | active: nil, retry_at: mono() + 5000}
  end

  defp endpoint(command, :cleanup), do: command.descriptor.source
  defp endpoint(command, _), do: command.descriptor.destination

  defp exchange(:cleanup, client, session, results),
    do: Client.exchange_relocation_cleanup(client, session, results)

  defp exchange(:readiness, client, session, results),
    do: Client.exchange_relocation_readiness(client, session, results)

  defp exchange(:import, client, session, results),
    do: Client.exchange_relocation_import(client, session, results)

  defp exchange(:receive, client, session, results),
    do: Client.exchange_relocation_receive(client, session, results)

  defp receipt(:cleanup, command, :deleted),
    do: %{id: command.id, descriptor: command.descriptor, generation: command.generation}

  defp receipt(:readiness, command, boot_id),
    do: %{
      id: command.id,
      descriptor: command.descriptor,
      generation: command.generation,
      boot_id: boot_id
    }

  defp receipt(_, command, guid),
    do: %{id: command.id, descriptor: command.descriptor, dataset_guid: guid}

  defp effect(:cleanup, config, _, command, store),
    do: Lilly.Transfer.SourceCleanup.execute(config, store, command)

  defp effect(:readiness, config, _, command, store),
    do: Lilly.Transfer.ReadinessProbe.execute(config, store, command)

  defp effect(:import, config, _, command, _),
    do:
      Lilly.Transfer.Importer.adopt(
        config,
        OverallsProtocol.RelocationImport.encode_command(command)
      )

  # @cc [owner:ghuntley,label:security;observability] transfer-failure-diagnostics-closed
  # Failed effects MUST expose only an allowlisted local reason through the
  # catalogued event. Never inspect result payloads, commands, descriptors,
  # paths or credentials. Identical consecutive failures MUST be suppressed
  # until success or a changed reason. Reporting MUST NOT create a receipt or
  # change lease/cleanup authority. Expired leases and effect task exits MUST
  # use fixed reasons without exposing exit payloads; stale timers MUST NOT
  # report a failure or stop renewed work.
  defp report_failure(state, failure) do
    reason =
      case failure do
        {:error, reason}
        when reason in [
               :effect_lease_expired,
               :effect_task_exited,
               :storage_busy,
               :receive_failed,
               :receive_authority_unconfirmed,
               :received_dataset_unconfirmed,
               :receive_busy,
               :receive_quiescence_unconfirmed,
               :receive_stream_unconfirmed,
               :invalid_transfer_connection,
               :invalid_ssh_transfer,
               :invalid_stream,
               :stream_busy,
               :stream_diagnostics_limit,
               :stream_failed,
               :stream_producer_failed,
               :stream_consumer_failed,
               :stream_children_failed,
               :stream_pipe_failed,
               :stream_helper_unavailable,
               :stream_revoked,
               :stream_timeout,
               :stream_unconfirmed,
               :import_authority_unconfirmed,
               :import_execution_unconfirmed,
               :import_jail_unconfirmed,
               :import_network_unconfirmed,
               :import_disk_adoption_unconfirmed,
               :import_ownership_unconfirmed,
               :import_claim_unconfirmed,
               :import_tombstone_unconfirmed,
               :import_intent_unconfirmed,
               :import_unit_unconfirmed,
               :import_adoption_unconfirmed,
               :import_publication_unconfirmed,
               :import_busy,
               :import_quiescence_unconfirmed,
               :disk_import_unconfirmed,
               :readiness_unconfirmed,
               :execution_unavailable,
               :readiness_timeout,
               :source_lease_unconfirmed,
               :source_command_unconfirmed,
               :source_exports_unconfirmed,
               :source_execution_unavailable,
               :source_claim_unconfirmed,
               :source_intent_unconfirmed,
               :source_unit_unconfirmed,
               :source_jail_unconfirmed,
               :source_network_unconfirmed,
               :source_fence_unconfirmed,
               :source_tombstone_unconfirmed,
               :source_boot_log_unconfirmed,
               :source_snapshots_unconfirmed,
               :source_disk_delete_unconfirmed,
               :source_cleanup_unconfirmed
             ] ->
          reason

        _ ->
          :effect_unconfirmed
      end

    if state.last_failure != reason do
      Lilly.Events.emit("lilly.transfer_effect_failed", reason: reason)
    end

    %{state | last_failure: reason}
  end

  defp mono, do: System.monotonic_time(:millisecond)

  defp task(fun),
    do:
      Task.async(fn ->
        Process.flag(:sensitive, true)

        try do
          fun.()
        rescue
          _ -> {:error, :receive_failed}
        catch
          _, _ -> {:error, :receive_failed}
        end
      end)
end
