defmodule Marshall.Terminal.PeerSocket do
  @moduledoc "Authenticated frontend-to-frontend forwarding to a local host stream."
  @behaviour WebSock
  alias OverallsProtocol.Terminal, as: Codec

  @liveness_ms 5_000
  @silence_ms 15_000

  # @cc [owner:ghuntley,label:security] peer-socket-current-local-stream
  # Peers MUST forward only to the local stream incarnation authenticated by
  # the upgrade proof. Stream loss MUST close the peer; peer loss MUST detach
  # its viewer without killing the guest session. No bytes enter the database.
  @impl true
  def init({host_id, nonce}) do
    Logger.metadata(marshall_terminal: true)

    budget_server = Marshall.Terminal.PeerBudget.server()

    with {:ok, stream} <- Marshall.Terminal.Relay.local_stream(host_id, nonce),
         {:ok, budget} <- Marshall.Terminal.PeerBudget.acquire(budget_server) do
      # The adapter owns this process and may consume monitor DOWN messages;
      # a watcher asks the callback to stop for this exact incarnation, with
      # an untrappable kill only as a bounded fallback.
      start_budget_watcher(self(), budget)

      Marshall.Terminal.Metrics.opened(:peer)
      Process.send_after(self(), :idle_deadline, 10_000)
      Process.send_after(self(), :liveness, @liveness_ms)

      {:ok,
       %{
         stream: stream,
         monitor: Process.monitor(stream),
         budget: budget,
         budget_monitor: Process.monitor(budget),
         channel: nil,
         input: 0,
         output: 0,
         phase: :idle,
         pending: nil,
         scope: nil,
         last_seen: System.monotonic_time(:millisecond)
       }}
    else
      _ -> {:stop, :normal, %{}}
    end
  end

  @impl true
  def handle_in({bytes, [opcode: :binary]}, state) do
    state = %{state | last_seen: System.monotonic_time(:millisecond)}

    case Codec.decode_frame(bytes) do
      {:ok, %{channel: 0, message: %{type: :output_ack, channel: channel} = message}}
      when state.phase == :attached and channel == state.channel ->
        send(state.stream, {:viewer_output_ack, channel, message.frames, message.bytes})
        {:ok, state}

      {:ok, %{channel: 0, message: message}}
      when state.phase == :idle and
             message.type in [
               :create,
               :listing,
               :boot_log,
               :creation_query,
               :creation_cancel,
               :users,
               :kill
             ] ->
        ref = make_ref()
        send(state.stream, {:relay_control, %{message: message, ref: ref, caller: self()}})
        {:ok, %{state | phase: :pending, pending: ref}}

      {:ok, %{channel: 0, message: %{type: :attach} = message}} when state.phase == :idle ->
        ref = make_ref()
        send(state.stream, {:viewer_attach, %{message: message, ref: ref, caller: self()}})

        {:ok,
         %{
           state
           | phase: :attaching,
             pending: ref,
             scope:
               Map.take(message, [
                 :vm_id,
                 :placement_id,
                 :execution_epoch,
                 :guest_session_id,
                 :mode
               ])
         }}

      {:ok, %{channel: 0, message: message}}
      when message.type == :resize and state.phase == :attached ->
        if state.scope.mode == :rw and
             Map.take(message, [:vm_id, :placement_id, :execution_epoch, :guest_session_id]) ==
               Map.delete(state.scope, :mode) do
          send(state.stream, {:relay_dispatch, message})
          {:ok, state}
        else
          {:stop, :normal, state}
        end

      {:ok, %{channel: channel, sequence: sequence, bytes: payload}}
      when state.phase == :attached and state.scope.mode == :rw and channel == state.channel and
             sequence > state.input ->
        send(state.stream, {:viewer_input, channel, payload})
        {:ok, %{state | input: sequence}}

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_in(_, state), do: {:stop, :normal, state}

  # The peer hop pings every five seconds; any frame proves it is alive.
  @impl true
  def handle_control(_frame, state),
    do: {:ok, %{state | last_seen: System.monotonic_time(:millisecond)}}

  @impl true
  def handle_info({:relay_reply, ref, {:ok, message}}, %{pending: ref, phase: :pending} = state),
    do: reply(message, %{state | phase: :complete, pending: nil})

  def handle_info({:relay_reply, _, {:error, _}}, state), do: {:stop, :normal, state}

  def handle_info({:terminal_attached, message}, %{phase: :attaching} = state),
    do: reply(message, %{state | channel: message.channel, phase: :attached, pending: nil})

  def handle_info({:terminal_output, bytes}, state) do
    sequence = state.output + 1

    {:reply, :ok, {:binary, Codec.encode_data_frame(state.channel, sequence, bytes)},
     %{state | output: sequence}}
  end

  def handle_info({:terminal_input_ack, frames, bytes}, %{phase: :attached} = state),
    do: reply(%{type: :input_ack, channel: state.channel, frames: frames, bytes: bytes}, state)

  def handle_info({:terminal_closed, _}, state), do: {:stop, :normal, state}
  def handle_info(:terminal_slow_viewer, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  # @cc [owner:ghuntley,label:security;recovery] peer-budget-loss-aborts-transport
  # Lost budget authority MUST abort the transport, not enter a graceful closing
  # state whose WebSock callbacks may still accept application traffic. Admission
  # under the successor budget MUST NOT revive an old incarnation's connection.
  def handle_info({:DOWN, ref, :process, _, _}, %{budget_monitor: ref} = state),
    do: {:stop, :peer_budget_lost, state}

  def handle_info({:terminal_budget_lost, budget}, %{budget: budget} = state),
    do: {:stop, :normal, state}

  # @cc [owner:ghuntley,label:recovery] peer-socket-liveness
  # A peer that has sent nothing for fifteen seconds MUST be treated as lost:
  # the socket stops, which detaches its channel from the host stream without
  # killing the guest session, so a dead Marshall node cannot hold output
  # credit or the shared terminal pump.
  def handle_info(:liveness, state) do
    remaining = @silence_ms - (System.monotonic_time(:millisecond) - state.last_seen)

    if remaining <= 0 do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :liveness, min(@liveness_ms, remaining))
      {:ok, state}
    end
  end

  def handle_info(:idle_deadline, %{phase: :attached} = state), do: {:ok, state}
  def handle_info(:idle_deadline, state), do: {:stop, :normal, state}

  def handle_info(_, state), do: {:ok, state}

  @impl true
  def terminate(_, %{channel: channel, stream: stream, budget: budget})
      when is_integer(channel) do
    Marshall.Terminal.PeerBudget.release(budget)
    send(stream, {:viewer_gone, channel})
    :ok
  end

  def terminate(_, %{budget: budget}), do: Marshall.Terminal.PeerBudget.release(budget)
  def terminate(_, _), do: :ok

  @spec start_budget_watcher(pid(), pid()) :: pid()
  defp start_budget_watcher(owner, budget) do
    spawn(fn -> budget_watcher(owner, budget) end)
  end

  @spec budget_watcher(pid(), pid()) :: :ok
  defp budget_watcher(owner, budget) do
    budget_monitor = Process.monitor(budget)
    owner_monitor = Process.monitor(owner)

    receive do
      {:DOWN, ^budget_monitor, :process, ^budget, _reason} ->
        send(owner, {:terminal_budget_lost, budget})

        receive do
          {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> :ok
        after
          1_000 -> Process.exit(owner, :kill)
        end

        :ok

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        :ok
    end
  end

  defp reply(message, state),
    do: {:reply, :ok, {:binary, Codec.encode_control_frame(message)}, state}
end
