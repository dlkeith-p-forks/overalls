defmodule Lilly.Terminal.ChannelHistoryTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias OverallsProtocol.Terminal, as: Codec
  alias OverallsProtocol.TerminalWindow, as: Window
  alias OverallsProtocol.WebSocket.Connection
  alias Lilly.Terminal.{Channel, Stream}

  @chunk 32_768
  @type stream_state :: %{
          client: %{host_id: String.t()},
          session: nil,
          runtime: pid(),
          phase: :authenticated,
          buffer: binary(),
          guests: map(),
          backoff: pos_integer(),
          channels: %{
            pos_integer() => %{
              pid: pid(),
              last_input: non_neg_integer(),
              input_window: Window.t()
            }
          },
          websocket: Connection.t()
        }

  # @cc [owner:ghuntley,label:verification] channel-history-local-scope
  # Histories MUST observe real local channel socket effects and decoded stream
  # frames. Synthetic bytes MUST NOT appear in failure diagnostics. These tests
  # MUST NOT claim guest PTY, TLS, native isolation or reconnect acceptance.
  property "replay credit histories preserve exact output and drain only after consumption" do
    check all(
            size <- member_of([1, 32_767, 32_768, 32_769, 262_143, 262_144, 262_145, 524_289]),
            stride <- member_of([1, 2, 7, 8, 9, 16]),
            channel_id <- member_of([1, 4_294_967_295]),
            max_runs: 24
          ) do
      # Every generated history contains a byte-exhaustion witness as well as
      # the drawn replay/receipt schedule.
      for {size, stride} <- [{size, stride}, {262_145, 9}] do
        with_channel(channel_id, fn channel, producer, state, receiver ->
          replay = :binary.copy(<<0, 27, 255>>, div(size + 2, 3)) |> binary_part(0, size)
          send(channel, {:activate, replay})
          total = div(size + @chunk - 1, @chunk)

          {frames, bytes} =
            Enum.reduce(1..total, {0, 0}, fn sequence, {acked, acknowledged_bytes} ->
              message = receive_output(channel, channel_id)
              {:channel_output, _, _, _, frame} = message
              decoded = decode_data(frame)
              assert decoded.sequence == sequence
              offset = (sequence - 1) * @chunk
              length = min(@chunk, size - offset)

              assert :crypto.hash(:sha256, decoded.bytes) ==
                       :crypto.hash(:sha256, binary_part(replay, offset, length))

              # Before forwarding, delivery has not been acknowledged. A barrier
              # observes the real channel process without relying on a sleep.
              snapshot = :sys.get_state(channel)
              assert snapshot.sequence == sequence
              assert is_reference(snapshot.delivery)
              no_output(channel, channel_id)
              unchanged(state, message)
              wire = receive_wire(receiver)
              assert :crypto.hash(:sha256, wire) == :crypto.hash(:sha256, frame)

              outstanding = sequence - acked
              assert outstanding <= Window.frame_limit()
              assert offset + length - acknowledged_bytes <= Window.byte_limit()

              if outstanding == 8 and sequence < total do
                stalled = :sys.get_state(channel)
                assert stalled.sequence == sequence
                assert stalled.delivery == nil
                no_output(channel, channel_id)
              end

              if (rem(sequence, stride) == 0 or outstanding == 8) and sequence < total do
                consumed = offset + length
                :ok = Channel.consumed(channel, sequence, consumed)
                # Duplicate and older cumulative receipts cannot grant more credit.
                :ok = Channel.consumed(channel, sequence, consumed)
                :ok = Channel.consumed(channel, acked, acknowledged_bytes)
                {sequence, consumed}
              else
                {acked, acknowledged_bytes}
              end
            end)

          assert frames < total
          assert bytes < size
          _ = :sys.get_state(channel)
          no_output(channel, channel_id)
          :ok = :gen_tcp.close(producer)
          eof = await_channel(channel, & &1.eof)
          assert eof.delivery == nil
          assert eof.window.pending != []

          receive do
            {:channel_closed, ^channel_id, _} -> flunk("channel closed before consumption")
          after
            0 -> :ok
          end

          :ok = Channel.consumed(channel, total, size)
          await_event(&match?({:channel_closed, ^channel_id, :session_exit}, &1))
        end)
      end
    end
  end

  property "transport loss stops old channels before a successor accepts queued output" do
    check all(
            size <- member_of([1, 32_768, 32_769, 262_145]),
            channel_id <- member_of([1, 4_294_967_295]),
            max_runs: 16
          ) do
      with_channel(channel_id, fn old, producer, state, receiver ->
        guests = %{{"synthetic-vm", "synthetic-placement", 1} => %{pid: self()}}
        state = %{state | guests: guests}
        send(old, {:activate, :binary.copy(<<42>>, size)})
        queued = receive_output(old, channel_id)
        monitor = Process.monitor(old)
        :ok = :gen_tcp.close(receiver.socket)
        disconnected = callback(state, {:tcp_closed, state.websocket.socket})
        assert disconnected.phase == :disconnected
        assert disconnected.channels == %{}
        assert disconnected.guests == guests
        await_event(&match?({:terminal_stream_ready, _, false}, &1))
        await_event(&match?({:DOWN, ^monitor, :process, ^old, :normal}, &1))
        socket_error(producer, :closed, 1000)

        # Reattachment is explicit. It gets a new local socket and starts a new
        # sequence space; uncertain input is never replayed by this history.
        with_channel(channel_id, fn successor, _producer, current, peer ->
          unchanged(current, queued)

          unchanged(current, {:channel_input_ack, old, channel_id, 1, 1})

          socket_error(peer.socket, :timeout, 1)
          send(successor, {:activate, <<42>>})
          message = receive_output(successor, channel_id)
          unchanged(current, message)

          decoded = decode_data(receive_wire(peer))
          assert decoded.channel == channel_id
          assert decoded.sequence == 1
        end)
      end)
    end
  end

  property "input duplicates have no socket effect and a gap fences only its channel" do
    check all(
            lengths <-
              list_of(member_of([1, 2, 125, 126, 32_768, 65_535]), min_length: 1, max_length: 6),
            gap <- member_of([2, 3, 65_535]),
            channel_id <- member_of([1, 4_294_967_295]),
            max_runs: 24
          ) do
      with_channel(channel_id, fn channel, producer, state, receiver ->
        sibling_id = if channel_id == 1, do: 2, else: 1

        with_channel(sibling_id, fn sibling, _producer, sibling_state, _receiver ->
          sibling_entry = sibling_state.channels[sibling_id]
          state = %{state | channels: Map.put(state.channels, sibling_id, sibling_entry)}

          state =
            lengths
            |> Enum.with_index(1)
            |> Enum.reduce(state, fn {length, sequence}, acc ->
              payload = :binary.copy(<<sequence>>, length)
              frame = Codec.encode_data_frame(channel_id, sequence, payload)
              next = pump(acc, receiver, frame)
              applied = socket_bytes(producer, length)
              assert :crypto.hash(:sha256, applied) == :crypto.hash(:sha256, payload)
              cumulative = next.channels[channel_id].input_window.sent_bytes
              ack = receive_ack(channel, channel_id)
              {:channel_input_ack, _, _, frames, bytes} = ack
              assert frames == sequence
              assert bytes == cumulative
              next = callback(next, ack)
              receipt = decode_control(receive_wire(receiver))

              assert receipt == %{
                       type: :input_ack,
                       channel: channel_id,
                       frames: sequence,
                       bytes: cumulative
                     }

              assert next.channels[channel_id].input_window.acknowledged_frames == sequence
              assert next.channels[channel_id].input_window.acknowledged_bytes == cumulative

              for stale <- Enum.uniq([sequence, 1]) do
                same_state(
                  next,
                  pump(next, receiver, Codec.encode_data_frame(channel_id, stale, payload))
                )

                _ = :sys.get_state(channel)
                socket_error(producer, :timeout, 1)

                receive do
                  {:channel_input_ack, ^channel, ^channel_id, _, _} ->
                    flunk("duplicate input receipt")
                after
                  0 -> :ok
                end
              end

              next
            end)

          monitor = Process.monitor(channel)

          next =
            pump(
              state,
              receiver,
              Codec.encode_data_frame(channel_id, length(lengths) + gap, <<42>>)
            )

          assert next.channels == %{sibling_id => sibling_entry}
          await_event(&match?({:DOWN, ^monitor, :process, ^channel, :normal}, &1))
          socket_error(producer, :closed, 1000)
          closed = receive_wire(receiver)

          assert decode_control(closed) == %{type: :closed, channel: channel_id, reason: :fenced}

          # Late messages from the stopped incarnation cannot forward output or ACKs.
          unchanged(next, {:channel_output, channel, channel_id, make_ref(), <<>>})

          unchanged(next, {:channel_input_ack, channel, channel_id, 1, 1})

          socket_error(receiver.socket, :timeout, 1)
          send(sibling, {:activate, <<42>>})
          output = receive_output(sibling, sibling_id)
          unchanged(next, output)

          decoded = decode_data(receive_wire(receiver))
          assert decoded.channel == sibling_id
          assert decoded.sequence == 1
        end)
      end)
    end
  end

  property "live frames stop at frame credit and malformed consumption fences the channel" do
    check all(
            length <- member_of([1, 125, 126, 127]),
            prefix <- member_of([1, 8, 15, 16]),
            invalid <- member_of([:future, :inconsistent]),
            max_runs: 16
          ) do
      with_channel(1, fn channel, producer, state, receiver ->
        payload = :binary.copy(<<1>>, length)
        send(channel, {:activate, payload})

        for sequence <- 1..16 do
          payload = :binary.copy(<<sequence>>, length)
          if sequence > 1, do: :ok = :gen_tcp.send(producer, payload)
          message = receive_output(channel, 1)
          {:channel_output, _, _, _, frame} = message
          decoded = decode_data(frame)
          assert decoded.sequence == sequence
          assert :crypto.hash(:sha256, decoded.bytes) == :crypto.hash(:sha256, payload)
          unchanged(state, message)
          wire = decode_data(receive_wire(receiver))
          assert wire.sequence == sequence
          _ = await_channel(channel, & &1.reading)
        end

        payload = :binary.copy(<<17>>, length)
        :ok = :gen_tcp.send(producer, payload)
        stalled = await_channel(channel, &(not &1.reading and &1.pending != []))
        assert stalled.sequence == 16
        assert stalled.window.sent_bytes == 16 * length
        assert stalled.window.sent_bytes < Window.byte_limit()
        assert stalled.delivery == nil
        no_output(channel, 1)
        :ok = Channel.consumed(channel, 0, 0)
        _ = :sys.get_state(channel)
        no_output(channel, 1)

        :ok = Channel.consumed(channel, prefix, prefix * length)
        message = receive_output(channel, 1)
        {:channel_output, _, _, _, frame} = message
        decoded = decode_data(frame)
        assert decoded.sequence == 17
        assert :crypto.hash(:sha256, decoded.bytes) == :crypto.hash(:sha256, payload)
        unchanged(state, message)
        assert decode_data(receive_wire(receiver)).sequence == 17
        :ok = Channel.consumed(channel, prefix, prefix * length)
        snapshot = :sys.get_state(channel)
        assert snapshot.window.acknowledged_frames == prefix
        assert snapshot.window.acknowledged_bytes == prefix * length

        monitor = Process.monitor(channel)

        {frames, bytes} =
          case invalid do
            :future -> {18, 18 * length}
            :inconsistent -> {17, 17 * length + 1}
          end

        :ok = Channel.consumed(channel, frames, bytes)
        await_event(&match?({:channel_closed, 1, :fenced}, &1))
        await_event(&match?({:DOWN, ^monitor, :process, ^channel, :normal}, &1))
        socket_error(producer, :closed, 1000)
      end)
    end
  end

  property "unacknowledged input credit fences before an excess guest effect" do
    check all(order <- member_of([[:frames, :bytes], [:bytes, :frames]]), max_runs: 8) do
      for family <- order do
        {length, accepted} = if family == :frames, do: {1, 16}, else: {65_535, 4}

        with_channel(1, fn channel, producer, state, receiver ->
          payload = :binary.copy(<<42>>, length)

          state =
            Enum.reduce(1..accepted, state, fn sequence, state ->
              next = pump(state, receiver, Codec.encode_data_frame(1, sequence, payload))
              applied = socket_bytes(producer, length)
              assert :crypto.hash(:sha256, applied) == :crypto.hash(:sha256, payload)
              ack = receive_ack(channel, 1)
              # Simulate delayed guest-effect receipts at the stream callback boundary.
              # The channel has written, but the stream has not yet released credit.
              {:channel_input_ack, _, _, frames, bytes} = ack
              assert frames == sequence
              assert bytes == sequence * length
              assert next.channels[1].input_window.acknowledged_frames == 0
              next
            end)

          monitor = Process.monitor(channel)
          next = pump(state, receiver, Codec.encode_data_frame(1, accepted + 1, payload))
          assert next.channels == %{}
          await_event(&match?({:DOWN, ^monitor, :process, ^channel, :normal}, &1))
          socket_error(producer, :closed, 1000)

          assert decode_control(receive_wire(receiver)) == %{
                   type: :closed,
                   channel: 1,
                   reason: :fenced
                 }
        end)
      end
    end
  end

  @spec callback(stream_state(), term()) :: stream_state()
  defp callback(state, message) do
    case Stream.handle_info(message, state) do
      {:noreply, next} when is_map(next) -> next
      _ -> flunk("unexpected stream callback result")
    end
  end

  @spec same_state(stream_state(), stream_state()) :: :ok
  defp same_state(expected, actual) do
    if expected == actual, do: :ok, else: flunk("stream state changed unexpectedly")
  end

  @spec unchanged(stream_state(), term()) :: :ok
  defp unchanged(state, message), do: same_state(state, callback(state, message))

  @spec await_event((term() -> boolean())) :: :ok
  defp await_event(predicate) do
    await_event(predicate, System.monotonic_time(:millisecond) + 1000, [])
  end

  @spec await_event((term() -> boolean()), integer(), [term()]) :: :ok
  defp await_event(predicate, deadline, deferred) do
    receive do
      message ->
        if predicate.(message) do
          Enum.each(Enum.reverse(deferred), &send(self(), &1))
          :ok
        else
          await_event(predicate, deadline, [message | deferred])
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Enum.each(Enum.reverse(deferred), &send(self(), &1))
        flunk("expected channel event before deadline")
    end
  end

  @type output :: {:channel_output, pid(), pos_integer(), reference(), binary()}
  @spec receive_output(pid(), pos_integer()) :: output()
  defp receive_output(channel, number) do
    receive do
      {:channel_output, ^channel, ^number, reference, frame} ->
        {:channel_output, channel, number, reference, frame}
    after
      1000 -> flunk("expected channel output before deadline")
    end
  end

  @spec no_output(pid(), pos_integer()) :: :ok
  defp no_output(channel, number) do
    receive do
      {:channel_output, ^channel, ^number, _, _} -> flunk("unexpected channel output")
    after
      0 -> :ok
    end
  end

  @spec receive_ack(pid(), pos_integer()) ::
          {:channel_input_ack, pid(), pos_integer(), non_neg_integer(), non_neg_integer()}
  defp receive_ack(channel, number) do
    receive do
      {:channel_input_ack, ^channel, ^number, frames, bytes} ->
        {:channel_input_ack, channel, number, frames, bytes}
    after
      1000 -> flunk("expected channel input receipt before deadline")
    end
  end

  @spec decode_data(binary()) :: %{
          channel: pos_integer(),
          sequence: pos_integer(),
          bytes: binary()
        }
  defp decode_data(frame) do
    case Codec.decode_frame(frame) do
      {:ok, %{channel: channel, sequence: sequence, bytes: bytes}} ->
        %{channel: channel, sequence: sequence, bytes: bytes}

      _ ->
        flunk("expected a valid data frame")
    end
  end

  @spec decode_control(binary()) :: map()
  defp decode_control(frame) do
    case Codec.decode_frame(frame) do
      {:ok, %{message: %{type: :input_ack} = message}} -> message
      {:ok, %{message: %{type: :closed} = message}} -> message
      _ -> flunk("expected a valid receipt or closure control")
    end
  end

  @spec socket_bytes(:gen_tcp.socket(), pos_integer()) :: binary()
  defp socket_bytes(socket, length) do
    case :gen_tcp.recv(socket, length, 1000) do
      {:ok, bytes} -> bytes
      _ -> flunk("expected socket bytes before deadline")
    end
  end

  @spec socket_error(:gen_tcp.socket(), :timeout | :closed, pos_integer()) :: :ok
  defp socket_error(socket, expected, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:error, ^expected} -> :ok
      _ -> flunk("unexpected socket effect")
    end
  end

  @spec await_channel(pid(), (map() -> boolean()), non_neg_integer()) :: map()
  defp await_channel(channel, predicate, remaining \\ 1000)

  defp await_channel(channel, predicate, remaining) when remaining > 0 do
    state = :sys.get_state(channel)

    if predicate.(state) do
      state
    else
      Process.sleep(1)
      await_channel(channel, predicate, remaining - 1)
    end
  catch
    :exit, _ -> flunk("channel stopped before expected state")
  end

  defp await_channel(_, _, _), do: flunk("channel state deadline exceeded")

  @spec receive_wire(Connection.t()) :: binary()
  defp receive_wire(peer) do
    assert {:ok, <<0x82, 1::1, size::7>>} = :gen_tcp.recv(peer.socket, 2, 1000)

    length =
      case size do
        126 ->
          assert {:ok, <<length::16>>} = :gen_tcp.recv(peer.socket, 2, 1000)
          length

        127 ->
          assert {:ok, <<length::64>>} = :gen_tcp.recv(peer.socket, 8, 1000)
          length

        length ->
          length
      end

    assert {:ok, mask} = :gen_tcp.recv(peer.socket, 4, 1000)
    bytes = socket_bytes(peer.socket, length)
    unmask(mask, bytes)
  end

  @spec unmask(binary(), binary()) :: binary()
  defp unmask(<<key::binary-size(4)>>, payload) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, :binary.at(key, rem(index, 4))) end)
    |> :binary.list_to_bin()
  end

  @spec pump(stream_state(), Connection.t(), binary()) :: stream_state()
  defp pump(state, peer, frame) do
    # The test peer is a server: RFC 6455 server frames are unmasked.
    size = byte_size(frame)

    header =
      cond do
        size < 126 -> <<0x82, size>>
        size <= 65_535 -> <<0x82, 126, size::16>>
        true -> <<0x82, 127, size::64>>
      end

    # Delivered as the transport message the active-once stream receives.
    _ = peer
    callback(state, {:tcp, state.websocket.socket, IO.iodata_to_binary([header, frame])})
  end

  @spec with_channel(pos_integer(), (pid(), :gen_tcp.socket(), stream_state(), Connection.t() ->
                                       term())) :: term()
  defp with_channel(number, operation) do
    {guest, producer} = sockets()
    {transport, receiver} = sockets()
    {:ok, channel} = Channel.start_link(self(), guest, number)
    :ok = :gen_tcp.controlling_process(guest, channel)

    state = %{
      client: %{host_id: Lilly.UUID.generate()},
      session: nil,
      runtime: self(),
      phase: :authenticated,
      buffer: <<>>,
      guests: %{},
      backoff: 30_000,
      channels: %{number => %{pid: channel, last_input: 0, input_window: Window.new()}},
      websocket: %Connection{socket: transport, transport: :plain, limit: 262_158}
    }

    try do
      operation.(channel, producer, state, %Connection{
        socket: receiver,
        transport: :plain,
        limit: 262_158
      })
    after
      Channel.stop(channel)
      Enum.each([guest, producer, transport, receiver], &:gen_tcp.close/1)
    end
  end

  @spec sockets() :: {:gen_tcp.socket(), :gen_tcp.socket()}
  defp sockets do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])

    try do
      {:ok, port} = :inet.port(listener)
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, server} = :gen_tcp.accept(listener)
      {client, server}
    after
      :gen_tcp.close(listener)
    end
  end
end
