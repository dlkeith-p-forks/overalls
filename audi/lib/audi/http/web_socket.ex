defmodule Audi.HTTP.WebSocket do
  @moduledoc "Bounded WebSocket message relay over the admitted local guest stream."
  @behaviour WebSock
  alias Audi.HTTP.{Authority, WebSocketFrame}
  require Audi.Events

  @impl true
  def init(state) do
    :logger.update_process_metadata(%{audi_private: true})
    :ok = :inet.setopts(state.socket, active: :once)
    {:ok, Map.merge(state, %{buffer: <<>>, fragment: nil})}
  end

  @impl true
  def handle_in({bytes, opcode: opcode}, state) do
    case send_frame(state.socket, opcode, bytes) do
      :ok -> {:ok, state}
      _ -> {:stop, :upstream_closed, state}
    end
  end

  # @cc [owner:ghuntley,label:security] audi-websocket-stream-backpressure
  # Guest reads MUST use active-once and bounded frame/message assembly. Only
  # valid complete text/binary messages may be emitted; controls cannot bypass
  # size/UTF-8 checks. The independent lease guard remains active after upgrade.
  @impl true
  def handle_info({:tcp, socket, bytes}, %{socket: socket} = state) do
    buffer = state.buffer <> bytes

    if byte_size(buffer) <= WebSocketFrame.maximum() + 65_550 do
      case frames(%{state | buffer: buffer}, []) do
        {:ok, state, messages} ->
          :ok = :inet.setopts(socket, active: :once)
          if messages == [], do: {:ok, state}, else: {:push, Enum.reverse(messages), state}

        :error ->
          {:stop, :invalid_upstream_frame, state}

        {:closed, state} ->
          {:stop, :normal, state}
      end
    else
      {:stop, :frame_limit, state}
    end
  end

  def handle_info({kind, socket}, %{socket: socket} = state) when kind == :tcp_closed,
    do: {:stop, :normal, state}

  def handle_info({:tcp_error, socket, _}, %{socket: socket} = state),
    do: {:stop, :upstream_closed, state}

  def handle_info(_, state), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    closed(state.binding, reason)
    Authority.finish(state.renewal)
    :gen_tcp.close(state.socket)
    :ok
  end

  defp closed(%{service: :editor} = binding, _reason), do: Audi.HTTP.Editor.closed(binding)

  defp closed(binding, reason) do
    Audi.Events.emit("audi.web_closed",
      host_id: binding.host_id,
      vm_id: binding.vm_id,
      placement_id: binding.placement_id,
      session_id: binding.session_id,
      execution_epoch: binding.execution_epoch,
      generation: binding.generation,
      reason: reason_atom(reason)
    )
  end

  defp reason_atom(reason) when is_atom(reason), do: reason
  defp reason_atom(_), do: :unknown

  defp frames(state, messages) do
    case WebSocketFrame.decode(state.buffer) do
      :more ->
        {:ok, state, messages}

      :error ->
        :error

      {:ok, frame, rest} ->
        state = %{state | buffer: rest}

        case accept(frame, state) do
          {:ok, state, nil} -> frames(state, messages)
          {:ok, state, message} -> frames(state, [message | messages])
          other -> other
        end
    end
  end

  defp accept(%{opcode: 8, payload: payload}, state) do
    if close_valid?(payload), do: {:closed, state}, else: :error
  end

  defp accept(%{opcode: 9, payload: payload}, state) do
    if send_frame(state.socket, :pong, payload) == :ok, do: {:ok, state, nil}, else: :error
  end

  defp accept(%{opcode: 10}, state), do: {:ok, state, nil}

  defp accept(%{opcode: opcode, payload: payload, final: final}, %{fragment: nil} = state)
       when opcode in [1, 2] do
    if final,
      do: message(opcode, payload, state),
      else: {:ok, %{state | fragment: {opcode, payload}}, nil}
  end

  defp accept(
         %{opcode: 0, payload: payload, final: final},
         %{fragment: {opcode, previous}} = state
       ) do
    if byte_size(previous) + byte_size(payload) <= WebSocketFrame.maximum() do
      payload = previous <> payload

      if final,
        do: message(opcode, payload, %{state | fragment: nil}),
        else: {:ok, %{state | fragment: {opcode, payload}}, nil}
    else
      :error
    end
  end

  defp accept(_, _), do: :error

  defp message(1, bytes, state),
    do: if(String.valid?(bytes), do: {:ok, state, {:text, bytes}}, else: :error)

  defp message(2, bytes, state), do: {:ok, state, {:binary, bytes}}
  defp close_valid?(<<>>), do: true

  defp close_valid?(<<code::16, reason::binary>>),
    do:
      (code in [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014] or
         code in 3000..4999) and String.valid?(reason)

  defp close_valid?(_), do: false

  defp send_frame(socket, opcode, bytes) do
    with {:ok, frame} <- WebSocketFrame.encode(opcode, bytes), do: :gen_tcp.send(socket, frame)
  end
end
