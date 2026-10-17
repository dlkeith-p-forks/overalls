defmodule Marshall.Terminal.HostStream do
  @moduledoc "WebSock handler for one Lilly terminal stream: hello binding, control routing and channel fan-out."
  @behaviour WebSock

  alias OverallsProtocol.Terminal, as: Codec
  alias OverallsProtocol.TerminalWindow, as: Window

  require Marshall.Events

  @max_buffer 262_144
  @viewer_mailbox_high_water 64
  @pending_limit 256
  @channel_limit 4096
  @request_timeout 5000
  @antithesis_harness System.get_env("ANTITHESIS_HARNESS") == "1"

  # @cc [owner:ghuntley,label:security] stream-hello-binds-execution-session
  # The first control frame MUST be a hello carrying the exact authenticated
  # host, execution session and epoch; any mismatch or non-hello first frame
  # closes the connection before any channel or control is accepted.
  # Terminal bytes passing through fan-out MUST never be logged.
  @impl true
  def init({host_id, session_id, epoch}) do
    Logger.metadata(marshall_terminal: true)

    state = %{
      host_id: host_id,
      session_id: session_id,
      epoch: epoch,
      hello: false,
      buffer: <<>>,
      channels: %{},
      viewers: %{},
      pending: %{},
      next_channel: 1
    }

    {:ok, state}
  end

  @impl true
  def handle_in({bytes, [opcode: :binary]}, state) do
    {state, frames} = consume(%{state | buffer: state.buffer <> bytes}, [])

    if state.hello == :rejected or byte_size(state.buffer) > @max_buffer do
      {:stop, :normal, state}
    else
      reply_with(frames, state)
    end
  end

  def handle_in({_bytes, _opcode}, %{hello: false} = state),
    do: {:stop, :normal, %{state | hello: :rejected, buffer: <<>>}}

  def handle_in({_bytes, _opcode}, state), do: {:ok, state}

  @impl true
  def handle_info({kind, request}, state)
      when kind in [:relay_control, :viewer_attach] and map_size(state.pending) >= @pending_limit do
    reply_to(request, {:error, :stream_busy})
    {:ok, state}
  end

  def handle_info(
        {:relay_control, %{message: %{type: :create}} = request},
        %{hello: true} = state
      ) do
    if Map.has_key?(state.pending, control_key(request.message)) do
      reply_to(request, {:error, :stream_busy})
      {:ok, state}
    else
      channel = state.next_channel
      message = Map.put(request.message, :channel, channel)
      request = Map.merge(request, %{message: message, channel: channel})
      pending = track(state.pending, control_key(message), request)

      {:reply, :ok, {:binary, Codec.encode_control_frame(message)},
       %{state | pending: pending, next_channel: channel + 1}}
    end
  end

  def handle_info({:relay_control, request}, state) do
    if state.hello == true and not Map.has_key?(state.pending, control_key(request.message)) do
      pending = track(state.pending, control_key(request.message), request)
      frame = Codec.encode_control_frame(request.message)
      {:reply, :ok, {:binary, frame}, %{state | pending: pending}}
    else
      reply_to(request, {:error, :stream_not_ready})
      {:ok, state}
    end
  end

  def handle_info({:relay_dispatch, message}, %{hello: true} = state) do
    {:reply, :ok, {:binary, Codec.encode_control_frame(message)}, state}
  end

  def handle_info({:relay_dispatch, _message}, state), do: {:ok, state}

  def handle_info({:viewer_input, channel, bytes}, state) do
    case state.channels[channel] do
      %{input_sequence: sequence} = entry when is_integer(sequence) and sequence >= 0 ->
        case Window.take(entry.input_window, byte_size(bytes)) do
          {:ok, window} ->
            frame = Codec.encode_data_frame(channel, sequence + 1, bytes)
            {wire, replay_receipt} = replay_frame(frame, state, entry, channel, sequence + 1)

            {:reply, :ok, {:binary, wire},
             put_in(state, [:channels, channel], %{
               entry
               | input_sequence: sequence + 1,
                 input_window: window,
                 replay_receipt: keep_replay_receipt(replay_receipt, entry.replay_receipt)
             })}

          _ ->
            close_viewer(state, channel)
        end

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:viewer_output_ack, channel, frames, bytes}, state) do
    with %{} = entry <- state.channels[channel],
         {:ok, window} <- Window.acknowledge(entry.output_window, frames, bytes) do
      message = %{type: :output_ack, channel: channel, frames: frames, bytes: bytes}

      {:reply, :ok, {:binary, Codec.encode_control_frame(message)},
       put_in(state, [:channels, channel, :output_window], window)}
    else
      nil -> {:ok, state}
      _ -> close_viewer(state, channel)
    end
  end

  def handle_info({:viewer_resize, message}, %{hello: true} = state) do
    {:reply, :ok, {:binary, Codec.encode_control_frame(message)}, state}
  end

  def handle_info({:viewer_resize, _message}, state), do: {:ok, state}

  def handle_info({:viewer_attach, request}, state) do
    if state.hello == true and map_size(state.channels) + map_size(state.pending) < @channel_limit and
         state.next_channel < 4_294_967_295 do
      channel = state.next_channel
      message = Map.put(request.message, :channel, channel)

      pending =
        track(state.pending, control_key(message), %{
          request
          | message: message
        })
        |> Map.update!(control_key(message), &Map.put(&1, :channel, channel))

      frame = Codec.encode_control_frame(message)
      {:reply, :ok, {:binary, frame}, %{state | pending: pending, next_channel: channel + 1}}
    else
      reply_to(request, {:error, :stream_not_ready})
      {:ok, state}
    end
  end

  def handle_info({:viewer_gone, channel}, state) do
    case Map.pop(state.channels, channel) do
      {nil, _} ->
        {:ok, state}

      {entry, channels} ->
        if entry[:monitor], do: Process.demonitor(entry.monitor, [:flush])
        frame = Codec.encode_control_frame(%{type: :channel_close, channel: channel})

        {:reply, :ok, {:binary, frame},
         %{state | channels: channels, viewers: Map.delete(state.viewers, channel)}}
    end
  end

  def handle_info(:relay_replaced, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.channels, fn {_channel, entry} -> entry[:monitor] == monitor end) do
      {channel, _} -> handle_info({:viewer_gone, channel}, state)
      nil -> {:ok, state}
    end
  end

  def handle_info(:renew_location, state) do
    result =
      with true <-
             Marshall.Terminal.Directory.current_execution?(
               state.host_id,
               state.session_id,
               state.epoch
             ),
           do: Marshall.Terminal.Relay.renew(state.host_id, self())

    case result do
      :ok ->
        Process.send_after(self(), :renew_location, 5000)
        {:ok, state}

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_info({:expire_request, key, reference}, state) do
    case state.pending[key] do
      %{expiry: ^reference} = request ->
        reply_to(request, {:error, :timeout})
        state = %{state | pending: Map.delete(state.pending, key)}

        case request[:channel] do
          channel when is_integer(channel) and channel > 0 ->
            frame = Codec.encode_control_frame(%{type: :channel_close, channel: channel})
            {:reply, :ok, {:binary, frame}, state}

          _ ->
            {:ok, state}
        end

      _ ->
        {:ok, state}
    end
  end

  def handle_info(_, state), do: {:ok, state}

  # @cc [owner:ghuntley,label:capacity] pending-controls-expire
  # Unanswered controls MUST expire after five seconds and pending requests MUST
  # remain bounded even when Lilly accepts the transport but never replies.
  defp track(pending, key, request) do
    reference = make_ref()
    Process.send_after(self(), {:expire_request, key, reference}, @request_timeout)
    Map.put(pending, key, Map.put(request, :expiry, reference))
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp consume(state, frames) do
    case Codec.decode_frame_prefix(state.buffer) do
      {:ok, %{channel: 0, message: control}, trailing} ->
        state = %{state | buffer: trailing}
        {state, frames} = apply_control(state, control, frames)
        consume(state, frames)

      {:ok, %{channel: _channel, sequence: _sequence, bytes: _bytes}, _trailing}
      when state.hello == false ->
        {%{state | hello: :rejected, buffer: <<>>}, frames}

      {:ok, %{channel: channel, sequence: sequence, bytes: bytes}, trailing} ->
        state = %{state | buffer: trailing}
        {state, frames} = forward_in_sequence(state, channel, sequence, bytes, frames)
        consume(state, frames)

      :partial ->
        {state, frames}

      {:error, _reason} ->
        {%{state | hello: :rejected, buffer: <<>>}, frames}
    end
  end

  defp apply_control(%{hello: false} = state, %{type: :hello} = message, frames) do
    if message.host_id == state.host_id and message.session_id == state.session_id and
         message.epoch == state.epoch and
         Marshall.Terminal.Directory.current_execution?(
           state.host_id,
           state.session_id,
           state.epoch
         ) do
      case Marshall.Terminal.Relay.register_authenticated(
             state.host_id,
             self(),
             state.session_id,
             state.epoch
           ) do
        :ok ->
          Marshall.Events.emit("terminal.stream_registered", host_id: state.host_id)
          Marshall.Terminal.Metrics.opened(:stream)
          Process.send_after(self(), :renew_location, 5000)

          frames = [
            Codec.encode_control_frame(%{type: :hello_response, interval_ms: 1000}) | frames
          ]

          {%{state | hello: true}, frames}

        _ ->
          {%{state | hello: :rejected}, frames}
      end
    else
      Marshall.Events.emit("terminal.stream_rejected", host_id: state.host_id)

      {%{state | hello: :rejected}, frames}
    end
  end

  defp apply_control(state, %{type: :hello}, frames), do: {%{state | hello: :rejected}, frames}

  defp apply_control(%{hello: false} = state, _message, frames),
    do: {%{state | hello: :rejected}, frames}

  defp apply_control(%{hello: :rejected} = state, _message, frames), do: {state, frames}

  defp apply_control(%{hello: true} = state, %{type: :heartbeat, sequence: sequence}, frames),
    do:
      {state,
       [Codec.encode_control_frame(%{type: :heartbeat_reply, sequence: sequence}) | frames]}

  defp apply_control(state, %{type: :attached} = message, frames) do
    case Map.pop(state.pending, {:attach, message.channel}) do
      {nil, _pending} ->
        {state, frames}

      {request, pending} ->
        if message.ok do
          send(request.caller, {:terminal_attached, message})

          channels =
            Map.put(state.channels, message.channel, %{
              input_sequence: 0,
              output_sequence: 0,
              input_window: Window.new(),
              output_window: Window.new(),
              monitor: Process.monitor(request.caller),
              terminal_session_id: Map.get(request, :terminal_session_id),
              vm_id: request.message.vm_id,
              placement_id: request.message.placement_id,
              execution_epoch: request.message.execution_epoch,
              guest_session_id: request.message.guest_session_id,
              replay_receipt: nil
            })

          viewers = Map.put(state.viewers, message.channel, request.caller)
          {%{state | pending: pending, viewers: viewers, channels: channels}, frames}
        else
          reply_to(request, {:error, message.reason})
          {state, frames}
        end
    end
  end

  defp apply_control(state, %{type: :input_ack, channel: channel} = message, frames) do
    with %{} = entry <- state.channels[channel],
         {:ok, window} <- Window.acknowledge(entry.input_window, message.frames, message.bytes) do
      send(state.viewers[channel], {:terminal_input_ack, message.frames, message.bytes})
      entry = acknowledge_replay(entry, channel, message.frames)
      {put_in(state, [:channels, channel], %{entry | input_window: window}), frames}
    else
      nil -> {state, frames}
      _ -> reject_output(state, channel, frames)
    end
  end

  defp apply_control(state, %{type: :closed, channel: channel} = message, frames) do
    notify_viewer(state.viewers[channel], message)

    if state.channels[channel] && state.channels[channel][:monitor],
      do: Process.demonitor(state.channels[channel].monitor, [:flush])

    {%{
       state
       | viewers: Map.delete(state.viewers, channel),
         channels: Map.delete(state.channels, channel)
     }, frames}
  end

  defp apply_control(state, message, frames) do
    case Map.pop(state.pending, control_key(message)) do
      {nil, _pending} ->
        {state, frames}

      {request, pending} ->
        reply_to(request, {:ok, message})

        case message do
          %{type: :closed} -> notify_viewer(state.viewers[request.channel], message)
          _ -> :ok
        end

        {%{state | pending: pending}, frames}
    end
  end

  defp notify_viewer(nil, _message), do: :ok

  defp notify_viewer(viewer, %{type: :closed} = message),
    do: send(viewer, {:terminal_closed, message})

  # @cc [owner:ghuntley,label:reliability;security] viewer-mailbox-isolation
  # Host output MUST NOT grow a viewer mailbox beyond the fixed high-water
  # mark. A slow viewer closes only its own host channel and MUST NOT block or
  # disconnect other viewers.

  # @cc [owner:ghuntley,label:protocol;reliability] output-gap-closes-channel
  # Replayed output sequences MUST be ignored, while a future sequence that
  # skips expected output MUST close its viewer channel so the browser can
  # reattach with a scrollback cursor instead of silently stalling.
  defp forward_in_sequence(state, channel, sequence, bytes, frames) do
    case state.channels[channel] do
      %{output_sequence: previous} = entry when sequence == previous + 1 ->
        case Window.take(entry.output_window, byte_size(bytes)) do
          {:ok, window} ->
            forward_to_viewer(state, channel, sequence, bytes, frames, %{
              entry
              | output_window: window
            })

          _ ->
            reject_output(state, channel, frames)
        end

      %{output_sequence: previous} when sequence > previous + 1 ->
        reject_output(state, channel, frames)

      _ ->
        {state, frames}
    end
  end

  defp forward_to_viewer(state, channel, sequence, bytes, frames, entry) do
    case state.viewers[channel] do
      viewer when is_pid(viewer) ->
        case Process.info(viewer, :message_queue_len) do
          {:message_queue_len, length} when length >= @viewer_mailbox_high_water ->
            send(viewer, :terminal_slow_viewer)
            if entry[:monitor], do: Process.demonitor(entry.monitor, [:flush])
            close = Codec.encode_control_frame(%{type: :channel_close, channel: channel})

            {%{
               state
               | channels: Map.delete(state.channels, channel),
                 viewers: Map.delete(state.viewers, channel)
             }, [close | frames]}

          _ ->
            send(viewer, {:terminal_output, bytes})

            {put_in(state, [:channels, channel], %{entry | output_sequence: sequence}), frames}
        end

      _ ->
        {state, frames}
    end
  end

  defp close_viewer(state, channel) do
    if is_pid(state.viewers[channel]),
      do: send(state.viewers[channel], {:terminal_closed, %{reason: :fenced}})

    handle_info({:viewer_gone, channel}, state)
  end

  defp reject_output(state, channel, frames) do
    case close_viewer(state, channel) do
      {:reply, :ok, {:binary, close}, next} -> {next, [close | frames]}
      {:ok, next} -> {next, frames}
    end
  end

  defp control_key(%{type: :attach, channel: channel}), do: {:attach, channel}
  defp control_key(%{type: :create, request_id: id}), do: {:create, id}
  defp control_key(%{type: :created, request_id: id}), do: {:create, id}
  defp control_key(%{type: :listing, vm_id: id}), do: {:listing, id}
  defp control_key(%{type: :listed, vm_id: id}), do: {:listing, id}

  defp control_key(%{type: type, vm_id: id}) when type in [:users, :users_listed],
    do: {:users, id}

  defp control_key(%{type: type, request_id: id})
       when type in [:creation_query, :creation_status],
       do: {:creation_query, id}

  defp control_key(%{type: type, request_id: id})
       when type in [:creation_cancel, :creation_cancelled],
       do: {:creation_cancel, id}

  defp control_key(%{
         type: type,
         vm_id: vm,
         placement_id: placement,
         execution_epoch: epoch,
         guest_session_id: id
       })
       when type in [:kill, :killed], do: {:kill, vm, placement, epoch, id}

  defp control_key(%{type: :resize, guest_session_id: id}), do: {:resize, id}

  defp control_key(%{type: type, vm_id: id}) when type in [:boot_log, :boot_log_data],
    do: {:boot_log, id}

  defp control_key(_), do: :unknown

  defp reply_with([], state), do: {:ok, state}
  defp reply_with(frames, state), do: {:reply, :ok, {:binary, frames}, state}

  defp reply_to(request, result), do: Marshall.Terminal.Relay.reply(request, result)

  if @antithesis_harness do
    @spec keep_replay_receipt(
            {String.t(), pos_integer()} | nil,
            {String.t(), pos_integer()} | nil
          ) ::
            {String.t(), pos_integer()} | nil
    defp keep_replay_receipt(new, previous), do: new || previous

    @spec replay_frame(binary(), map(), map(), pos_integer(), pos_integer()) ::
            {binary(), {String.t(), pos_integer()} | nil}
    defp replay_frame(frame, state, entry, channel, sequence),
      do:
        OverallsAntithesis.Marshall.TerminalReplay.maybe_duplicate(
          frame,
          state,
          entry,
          channel,
          sequence
        )

    @spec acknowledge_replay(map(), pos_integer(), non_neg_integer()) :: map()
    defp acknowledge_replay(%{replay_receipt: {request_id, sequence}} = entry, channel, frames)
         when frames >= sequence do
      OverallsAntithesis.Marshall.TerminalReplay.acknowledge(
        request_id,
        channel,
        sequence,
        frames
      )

      %{entry | replay_receipt: nil}
    end

    defp acknowledge_replay(entry, _channel, _frames), do: entry
  else
    @spec keep_replay_receipt(nil, nil) :: nil
    defp keep_replay_receipt(_new, _previous), do: nil

    @spec replay_frame(binary(), map(), map(), pos_integer(), pos_integer()) :: {binary(), nil}
    defp replay_frame(frame, _state, _entry, _channel, _sequence), do: {frame, nil}

    @spec acknowledge_replay(map(), pos_integer(), non_neg_integer()) :: map()
    defp acknowledge_replay(entry, _channel, _frames), do: entry
  end
end
