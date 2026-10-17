defmodule Marshall.Terminal.Remote do
  require Marshall.Events

  @moduledoc "Ephemeral TLS peer hop; terminal bytes are never persisted."
  use GenServer
  alias OverallsProtocol.Terminal
  alias OverallsProtocol.WebSocket.Connection

  @heartbeat_ms 5_000
  @silence_ms 15_000

  @spec start(pid(), Marshall.Terminal.Location.t()) :: {:ok, pid()} | {:error, atom()}
  def start(owner, location) do
    case GenServer.start(__MODULE__, {owner, location}) do
      {:ok, pid} -> {:ok, pid}
      _ -> {:error, :stream_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security] peer-hop-ephemeral-and-authenticated
  # Peer hops MUST use verified TLS and a short-lived purpose-bound proof tied
  # to the current directory nonce. Tokens and terminal buffers MUST NOT appear
  # in status reports. Owner death MUST close the peer hop and its attachment.
  @impl true
  def init({owner, location}) do
    Logger.metadata(marshall_terminal: true)
    monitor = Process.monitor(owner)

    proof =
      Phoenix.Token.sign(
        MarshallWeb.Endpoint,
        "terminal-peer-v1",
        {location.host_id, location.nonce}
      )

    options = [
      headers: [{"authorization", "TerminalPeer " <> proof}],
      cacertfile: Application.get_env(:marshall, :terminal_peer_ca),
      limit: 262_158
    ]

    with {:ok, budget} <- Marshall.Terminal.PeerBudget.acquire(),
         {:ok, socket} <- Connection.open(location.uri, "/api/terminal-peer/v1/stream", options) do
      Marshall.Terminal.Metrics.opened(:peer)
      Process.send_after(self(), :check_location, 5000)
      Process.send_after(self(), :idle_deadline, 10_000)
      Process.send_after(self(), :heartbeat, @heartbeat_ms)
      Process.send_after(self(), :silence_deadline, @silence_ms)
      send(self(), {:pending_frames, Connection.pending(socket)})

      {:ok,
       %{
         socket: socket,
         host_id: location.host_id,
         nonce: location.nonce,
         owner: owner,
         monitor: monitor,
         budget_monitor: Process.monitor(budget),
         pending: nil,
         viewer: nil,
         channel: nil,
         sequence: 0,
         output_sequence: 0,
         buffer: <<>>,
         last_seen: System.monotonic_time(:millisecond)
       }}
    else
      _ ->
        {:stop, :peer_unavailable}
    end
  end

  @impl true
  def handle_info(
        {kind, %{caller: caller} = request},
        %{owner: caller, pending: nil, viewer: nil} = state
      )
      when kind in [:relay_control, :viewer_attach] do
    message =
      if request.message.type in [:create, :attach],
        do: Map.put(request.message, :channel, 1),
        else: request.message

    case Connection.send_frame(state.socket, {:binary, Terminal.encode_control_frame(message)}) do
      :ok -> {:noreply, %{state | pending: request}}
      _ -> {:stop, :normal, state}
    end
  end

  def handle_info({kind, request}, state) when kind in [:relay_control, :viewer_attach] do
    Marshall.Terminal.Relay.reply(request, {:error, :stream_busy})
    {:noreply, state}
  end

  def handle_info({:relay_dispatch, message}, state) do
    Connection.send_frame(state.socket, {:binary, Terminal.encode_control_frame(message)})
    {:stop, :normal, state}
  end

  def handle_info({:viewer_input, channel, bytes}, %{channel: channel} = state) do
    next = state.sequence + 1

    case Connection.send_frame(
           state.socket,
           {:binary, Terminal.encode_data_frame(channel, next, bytes)}
         ) do
      :ok -> {:noreply, %{state | sequence: next}}
      _ -> {:stop, :normal, state}
    end
  end

  def handle_info({:viewer_resize, message}, state) do
    case Connection.send_frame(state.socket, {:binary, Terminal.encode_control_frame(message)}) do
      :ok -> {:noreply, state}
      _ -> {:stop, :normal, state}
    end
  end

  def handle_info({:viewer_gone, _}, state), do: {:stop, :normal, state}

  def handle_info({:viewer_output_ack, channel, frames, bytes}, %{channel: channel} = state) do
    message = %{type: :output_ack, channel: channel, frames: frames, bytes: bytes}

    case Connection.send_frame(state.socket, {:binary, Terminal.encode_control_frame(message)}) do
      :ok -> {:noreply, state}
      _ -> {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{budget_monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(:idle_deadline, %{viewer: nil} = state), do: {:stop, :normal, state}

  def handle_info(:check_location, state) do
    case Marshall.Terminal.Directory.lookup(state.host_id) do
      {:ok, %{nonce: nonce}} when nonce == state.nonce ->
        Process.send_after(self(), :check_location, 5000)
        {:noreply, state}

      _ ->
        Marshall.Events.emit("terminal.stream_fenced", host_id: state.host_id)
        {:stop, :normal, state}
    end
  end

  # @cc [owner:ghuntley,label:recovery] peer-hop-liveness
  # The peer hop MUST receive actively (nothing polls), ping its peer every
  # five seconds and stop after fifteen seconds without hearing from it, so a
  # lost Marshall node releases its viewer instead of holding it forever.
  def handle_info(:heartbeat, state) do
    if System.monotonic_time(:millisecond) - state.last_seen >= @silence_ms do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :heartbeat, @heartbeat_ms)

      case Connection.send_frame(state.socket, {:ping, <<>>}) do
        :ok -> {:noreply, state}
        _ -> {:stop, :normal, state}
      end
    end
  end

  # @cc [owner:ghuntley,label:recovery] peer-hop-silence-wakeup
  # An unexpired silence check MUST wake within its remaining fifteen-second
  # budget; expired silence MUST stop the hop independently of ping cadence.
  def handle_info(:silence_deadline, state) do
    remaining = @silence_ms - (System.monotonic_time(:millisecond) - state.last_seen)

    if remaining <= 0 do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :silence_deadline, remaining)
      {:noreply, state}
    end
  end

  def handle_info({:pending_frames, result}, state), do: transport(state, result)

  def handle_info(message, %{socket: %Connection{} = socket} = state) do
    case Connection.stream(socket, message) do
      :unknown -> {:noreply, state}
      result -> transport(state, result)
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @spec transport(map(), term()) :: {:noreply, map()} | {:stop, :normal, map()}
  defp transport(state, {:ok, socket, frames}) do
    state = %{state | socket: socket, last_seen: System.monotonic_time(:millisecond)}

    Enum.reduce_while(frames, {:noreply, state}, fn
      {:binary, bytes}, {:noreply, state} ->
        case consume(%{state | buffer: state.buffer <> bytes}) do
          {:ok, state} -> {:cont, {:noreply, state}}
          {:stop, state} -> {:halt, {:stop, :normal, state}}
        end

      {:close, _code, _reason}, {:noreply, state} ->
        {:halt, {:stop, :normal, state}}

      _other, acc ->
        {:cont, acc}
    end)
  end

  defp transport(state, _closed_or_error), do: {:stop, :normal, state}

  defp consume(state) do
    case Terminal.decode_frame_prefix(state.buffer) do
      {:ok, %{channel: 0, message: %{type: :attached, ok: true} = message}, rest}
      when not is_nil(state.pending) ->
        send(state.pending.caller, {:terminal_attached, message})

        consume(%{
          state
          | buffer: rest,
            viewer: state.pending.caller,
            pending: nil,
            channel: message.channel
        })

      {:ok, %{channel: 0, message: %{type: :input_ack, channel: channel} = message}, rest}
      when channel == state.channel and not is_nil(state.viewer) ->
        send(state.viewer, {:terminal_input_ack, message.frames, message.bytes})
        consume(%{state | buffer: rest})

      {:ok, %{channel: 0, message: %{type: :closed} = message}, _} ->
        if state.viewer, do: send(state.viewer, {:terminal_closed, message})
        {:stop, state}

      {:ok, %{channel: 0, message: message}, _} when not is_nil(state.pending) ->
        result = if message.type == :attached, do: {:error, message.reason}, else: {:ok, message}
        Marshall.Terminal.Relay.reply(state.pending, result)
        {:stop, %{state | pending: nil}}

      {:ok, %{channel: channel, sequence: sequence, bytes: bytes}, rest}
      when channel == state.channel and not is_nil(state.viewer) and
             sequence == state.output_sequence + 1 ->
        case Process.info(state.viewer, :message_queue_len) do
          {:message_queue_len, length} when length < 64 ->
            send(state.viewer, {:terminal_output, bytes})
            consume(%{state | buffer: rest, output_sequence: sequence})

          _ ->
            {:stop, state}
        end

      :partial ->
        {:ok, state}

      _ ->
        {:stop, state}
    end
  end

  @impl true
  def terminate(_, state) do
    Marshall.Terminal.PeerBudget.release()
    Connection.close(state.socket)

    if state.pending,
      do: Marshall.Terminal.Relay.reply(state.pending, {:error, :stream_unavailable})

    if state.viewer, do: send(state.viewer, {:terminal_closed, %{reason: :stream_unavailable}})
    :ok
  end

  @impl true
  def format_status(_options, _state), do: %{data: [{"State", :redacted}]}
end
