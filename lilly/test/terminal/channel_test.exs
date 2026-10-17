defmodule Lilly.Terminal.ChannelTest do
  use ExUnit.Case, async: true

  alias OverallsProtocol.Terminal, as: Codec
  alias Lilly.Terminal.{Channel, Stream}
  alias OverallsProtocol.WebSocket.Connection

  test "transport loss retains guest managers and their reattach authority" do
    {transport, peer} = sockets()
    :gen_tcp.close(peer)
    guests = %{{"vm", "placement", 1} => %{pid: self()}}

    state = %{
      phase: :authenticated,
      channels: %{},
      guests: guests,
      runtime: self(),
      client: %{host_id: Lilly.UUID.generate()},
      backoff: 30_000,
      buffer: <<>>,
      websocket: %Connection{socket: transport, transport: :plain, limit: 262_158}
    }

    assert {:noreply, disconnected} = Stream.handle_info({:tcp_closed, transport}, state)
    assert disconnected.phase == :disconnected
    assert disconnected.guests == guests
    assert_receive {:terminal_stream_ready, _, false}
  end

  test "replay and live bytes use masked WebSocket frames and acknowledgement backpressure" do
    {guest, producer} = sockets()
    {transport, receiver} = sockets()
    channel = start_supervised!(%{id: Channel, start: {Channel, :start_link, [self(), guest, 7]}})
    :ok = :gen_tcp.controlling_process(guest, channel)
    replay = :binary.copy(<<0, 255>>, 20_000)
    send(channel, {:activate, replay})

    state = %{
      phase: :authenticated,
      channels: %{7 => %{pid: channel}},
      websocket: %Connection{socket: transport, transport: :plain, limit: 262_158}
    }

    assert_receive {:channel_output, ^channel, 7, first, frame} = message, 1000
    assert {:ok, %{sequence: 1, bytes: bytes}} = Codec.decode_frame(frame)
    assert bytes == binary_part(replay, 0, 32_768)
    refute_receive {:channel_output, ^channel, 7, _, _}, 20
    assert {:noreply, ^state} = Stream.handle_info(message, state)
    assert_masked(receiver, frame)

    assert_receive {:channel_output, ^channel, 7, second, frame} = message, 1000
    assert first != second
    assert {:ok, %{sequence: 2, bytes: bytes}} = Codec.decode_frame(frame)
    assert bytes == binary_part(replay, 32_768, 7232)
    assert {:noreply, ^state} = Stream.handle_info(message, state)
    assert_masked(receiver, frame)

    :ok = :gen_tcp.send(producer, <<27, 0, 255>>)
    assert_receive {:channel_output, ^channel, 7, _, frame} = message, 1000
    assert {:ok, %{sequence: 3, bytes: <<27, 0, 255>>}} = Codec.decode_frame(frame)
    assert {:noreply, ^state} = Stream.handle_info(message, state)
    assert_masked(receiver, frame)
  end

  test "local socket delivery cannot outrun browser consumption and EOF drains outstanding output" do
    {guest, producer} = sockets()

    channel =
      start_supervised!(%{
        id: Channel,
        restart: :temporary,
        start: {Channel, :start_link, [self(), guest, 7]}
      })

    :ok = :gen_tcp.controlling_process(guest, channel)
    send(channel, {:activate, :binary.copy(<<42>>, 9 * 32_768)})

    for sequence <- 1..8 do
      assert_receive {:channel_output, ^channel, 7, reference, frame}, 1000
      assert {:ok, %{sequence: ^sequence}} = Codec.decode_frame(frame)
      send(channel, {:delivered, reference})
    end

    _ = :sys.get_state(channel)
    refute_receive {:channel_output, ^channel, 7, _, _}, 50
    :ok = Channel.consumed(channel, 8, 8 * 32_768)
    assert_receive {:channel_output, ^channel, 7, reference, frame}, 1000
    assert {:ok, %{sequence: 9, bytes: bytes}} = Codec.decode_frame(frame)
    assert bytes == :binary.copy(<<42>>, 32_768)
    send(channel, {:delivered, reference})
    :gen_tcp.close(producer)
    refute_receive {:channel_closed, 7, _}, 50
    :ok = Channel.consumed(channel, 9, 9 * 32_768)
    assert_receive {:channel_closed, 7, :session_exit}, 1000
  end

  @spec sockets() :: {:gen_tcp.socket(), :gen_tcp.socket()}
  defp sockets do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    {:ok, server} = :gen_tcp.accept(listener)
    :gen_tcp.close(listener)

    on_exit(fn ->
      :gen_tcp.close(client)
      :gen_tcp.close(server)
    end)

    {client, server}
  end

  @spec assert_masked(:gen_tcp.socket(), binary()) :: :ok
  defp assert_masked(socket, expected) do
    assert {:ok, <<0x82, 1::1, size::7>>} = :gen_tcp.recv(socket, 2, 1000)

    length =
      if size == 126 do
        assert {:ok, <<length::16>>} = :gen_tcp.recv(socket, 2, 1000)
        length
      else
        size
      end

    assert {:ok, mask} = :gen_tcp.recv(socket, 4, 1000)
    assert {:ok, payload} = :gen_tcp.recv(socket, length, 1000)
    assert unmask(mask, payload) == expected
    :ok
  end

  @spec unmask(binary(), binary()) :: binary()
  defp unmask(<<key::binary-size(4)>>, payload) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, :binary.at(key, rem(index, 4))) end)
    |> :binary.list_to_bin()
  end
end
