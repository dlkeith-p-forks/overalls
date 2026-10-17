defmodule Overalls.RequestAccounting.Producer.Server do
  @moduledoc false
  use GenServer
  alias Overalls.RequestAccounting.{Config, QualityMarker, RecorderRPC}
  alias Overalls.RequestAccounting.Producer

  @heartbeat_ms 5_000
  @max_pending 4_096
  @max_counter 9_223_372_036_854_775_807

  @type pending :: %{id: pos_integer(), owner: pid(), issuer: pid(), started_us: integer()}
  @type state :: %{
          socket: binary(),
          directory: binary(),
          gap: boolean(),
          pending: %{reference() => pending()}
        }

  @impl true
  @spec init(Config.t()) :: {:ok, state()}
  def init(%Config{} = config) do
    Process.flag(:trap_exit, true)
    directory = config.directory
    previous = QualityMarker.read(directory)
    usable = QualityMarker.write(directory, :running) == :ok

    state = %{
      socket: config.socket,
      directory: directory,
      gap: previous != {:ok, :clean} or not usable,
      pending: %{}
    }

    state = recover(state)
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:ok, state}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) ::
          {:reply, Producer.ticket() | :ok, state()}
  def handle_call({:admit, owner, valid_until}, {issuer, _tag}, state) do
    if not valid_owner?(owner) or not is_pid(issuer) or not is_integer(valid_until) or
         System.monotonic_time(:millisecond) > valid_until or
         map_size(state.pending) >= @max_pending do
      {:reply, :unrecorded, mark_gap(state)}
    else
      state = recover(state)

      case if(state.gap,
             do: {:error, :unavailable},
             else: RecorderRPC.call(state.socket, %{op: :admit})
           ) do
        {:admitted, id} ->
          ticket = Process.monitor(owner)

          entry = %{
            id: id,
            owner: owner,
            issuer: issuer,
            started_us: System.monotonic_time(:microsecond)
          }

          {:reply, ticket, %{state | pending: Map.put(state.pending, ticket, entry)}}

        _ ->
          {:reply, :unrecorded, mark_gap(state)}
      end
    end
  end

  def handle_call({:complete, ticket, outcome, duration_us}, {owner, _tag}, state) do
    case Map.get(state.pending, ticket) do
      %{owner: worker, issuer: issuer} = entry when owner == worker or owner == issuer ->
        state = settle(state, entry, outcome, duration_us)
        Process.demonitor(ticket, [:flush])
        {:reply, :ok, %{state | pending: Map.delete(state.pending, ticket)}}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call(_message, _from, state), do: {:reply, :unrecorded, state}

  @impl true
  @spec handle_cast(:gap, state()) :: {:noreply, state()}
  def handle_cast(:gap, state), do: {:noreply, mark_gap(state)}

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info(:heartbeat, state) do
    state = recover(state)

    state =
      if not state.gap and RecorderRPC.call(state.socket, %{op: :hello}) != :ok,
        do: mark_gap(state),
        else: state

    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:noreply, state}
  end

  # @cc [owner:ghuntley,label:reliability;security] producer-monitored-death-proof
  # A DOWN tuple MUST settle only its pending ticket's actual local worker after
  # that worker is confirmed dead. A tuple for a live or different worker MUST
  # preserve the admission and MUST NOT suppress authorized completion.
  def handle_info({:DOWN, ticket, :process, owner, _reason}, state) do
    case Map.get(state.pending, ticket) do
      %{owner: ^owner} = entry ->
        if Process.alive?(owner) do
          {:noreply, state}
        else
          duration =
            min(@max_counter, max(0, System.monotonic_time(:microsecond) - entry.started_us))

          {:noreply,
           %{
             settle(state, entry, :failure, duration)
             | pending: Map.delete(state.pending, ticket)
           }}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # @cc [owner:ghuntley,label:reliability] producer-clean-shutdown-coverage
  # Only a graceful shutdown with no outstanding admission and no recording gap
  # MAY persist clean. Unclean client/application restarts MUST report a gap
  # before healthy heartbeat or admission; permanent metric lifetime stays intact.
  @impl true
  @spec terminate(term(), state()) :: :ok
  def terminate(reason, state) do
    graceful = reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)

    quality =
      if graceful and not state.gap and map_size(state.pending) == 0, do: :clean, else: :gap

    _result = QualityMarker.write(state.directory, quality)
    :ok
  end

  @spec mark_gap(state()) :: state()
  defp mark_gap(state) do
    _result = QualityMarker.write(state.directory, :gap)
    # A storage failure still reports incomplete coverage to the durable recorder;
    # local state stays dirty until both durable boundaries agree.
    _reported = RecorderRPC.call(state.socket, %{op: :gap})
    %{state | gap: true}
  end

  @spec recover(state()) :: state()
  defp recover(%{gap: false} = state) do
    if QualityMarker.read(state.directory) == {:ok, :running}, do: state, else: mark_gap(state)
  end

  defp recover(state) do
    with :ok <- QualityMarker.write(state.directory, :gap),
         :ok <- RecorderRPC.call(state.socket, %{op: :gap}),
         :ok <- QualityMarker.write(state.directory, :running) do
      %{state | gap: false}
    else
      _ -> mark_gap(state)
    end
  end

  @spec settle(state(), pending(), :success | :failure | :exclude, non_neg_integer()) :: state()
  defp settle(state, entry, outcome, duration_us) do
    state = recover(state)
    command = %{op: :finish, id: entry.id, outcome: outcome, duration_us: duration_us}
    reported = not state.gap or RecorderRPC.call(state.socket, %{op: :gap}) == :ok

    if reported and RecorderRPC.call(state.socket, command) == :ok,
      do: state,
      else: mark_gap(state)
  end

  @spec valid_owner?(term()) :: boolean()
  defp valid_owner?(owner), do: is_pid(owner) and node(owner) == node()
end
