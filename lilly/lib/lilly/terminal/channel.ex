defmodule Lilly.Terminal.Channel do
  @moduledoc "One attached guest terminal socket pumped onto its stream channel."
  use GenServer

  alias Lilly.Terminal.Vsock
  alias OverallsProtocol.TerminalWindow, as: Window

  @chunk 32_768

  # @cc [owner:ghuntley,label:recovery] channel-delivery-order
  # The channel MUST forward guest bytes to the stream in arrival order with
  # strictly increasing output sequences, forward input bytes verbatim, and
  # close only itself, never the guest session, on socket loss. Only the stream
  # may write WebSocket frames; the channel MUST wait for delivery acknowledgement
  # before rearming guest reads so a stalled stream cannot accumulate output.
  @spec start_link(
          pid(),
          Vsock.socket(),
          pos_integer()
        ) ::
          GenServer.on_start()
  def start_link(stream, guest_socket, channel) do
    GenServer.start_link(
      __MODULE__,
      {stream, guest_socket, channel}
    )
  end

  @spec input(pid(), pos_integer(), binary()) :: :ok
  def input(channel, sequence, bytes) do
    send(channel, {:input, sequence, bytes})
    :ok
  end

  @spec consumed(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  def consumed(channel, frames, bytes) do
    send(channel, {:consumed, frames, bytes})
    :ok
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(channel) do
    GenServer.stop(channel, :normal)
    :ok
  catch
    :exit, {:noproc, _} -> :ok
  end

  @impl true
  def init({stream, guest_socket, channel}) do
    {:ok,
     %{
       stream: stream,
       guest_socket: guest_socket,
       channel: channel,
       sequence: 0,
       pending: [],
       delivery: nil,
       window: Window.new(),
       input_bytes: 0,
       reading: false,
       eof: false
     }}
  end

  @impl true
  def handle_info({:activate, replay}, state) do
    deliver(state, replay)
  end

  def handle_info({:delivered, reference}, %{delivery: reference} = state) do
    send_next(%{state | delivery: nil})
  end

  def handle_info({:consumed, frames, bytes}, state) do
    case Window.acknowledge(state.window, frames, bytes) do
      {:ok, window} when is_nil(state.delivery) ->
        send_next(%{state | window: window})

      {:ok, window} ->
        {:noreply, %{state | window: window}}

      _ ->
        report(state, :fenced)
        {:stop, :normal, state}
    end
  end

  def handle_info({:tcp, socket, bytes}, %{guest_socket: socket} = state) do
    deliver(%{state | reading: false}, bytes)
  end

  def handle_info({:tcp_closed, socket}, %{guest_socket: socket} = state) do
    send_next(%{state | reading: false, eof: true})
  end

  def handle_info({:tcp_error, socket, _reason}, %{guest_socket: socket} = state) do
    report(state, :session_exit)
    {:stop, :normal, state}
  end

  def handle_info({:input, sequence, bytes}, state) do
    case Vsock.write(state.guest_socket, bytes) do
      :ok ->
        total = state.input_bytes + byte_size(bytes)
        send(state.stream, {:channel_input_ack, self(), state.channel, sequence, total})
        {:noreply, %{state | input_bytes: total}}

      {:error, _reason} ->
        report(state, :session_exit)
        {:stop, :normal, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Vsock.close(state.guest_socket)
    :ok
  end

  @impl true
  def format_status(_opt, state) do
    %{data: [{"State", %{channel: state.channel, sequence: state.sequence}}]}
  end

  defp deliver(state, bytes) do
    {chunks, _count} = chunk(bytes)
    send_next(%{state | pending: chunks})
  end

  defp send_next(%{pending: [], eof: true, window: %{pending: []}, delivery: nil} = state) do
    report(state, :session_exit)
    {:stop, :normal, state}
  end

  defp send_next(%{pending: [], eof: true} = state), do: {:noreply, state}
  defp send_next(%{pending: [], reading: true} = state), do: {:noreply, state}

  defp send_next(%{pending: []} = state) do
    :ok = :inet.setopts(state.guest_socket, active: :once)
    {:noreply, %{state | reading: true}}
  end

  defp send_next(%{pending: [first | rest]} = state) do
    case Window.take(state.window, byte_size(first)) do
      {:ok, window} -> send_chunk(%{state | window: window}, first, rest)
      {:error, :exhausted} -> {:noreply, state}
    end
  end

  defp send_chunk(state, first, rest) do
    sequence = state.sequence + 1
    frame = OverallsProtocol.Terminal.encode_data_frame(state.channel, sequence, first)
    reference = make_ref()
    send(state.stream, {:channel_output, self(), state.channel, reference, frame})
    {:noreply, %{state | sequence: sequence, pending: rest, delivery: reference}}
  end

  defp chunk(bytes) do
    count = div(byte_size(bytes), @chunk) + if(rem(byte_size(bytes), @chunk) == 0, do: 0, else: 1)

    chunks =
      for index <- 0..(count - 1)//1,
          do: binary_part(bytes, index * @chunk, min(@chunk, byte_size(bytes) - index * @chunk))

    {chunks, count}
  end

  defp report(state, reason) do
    send(state.stream, {:channel_closed, state.channel, reason})
  end
end
