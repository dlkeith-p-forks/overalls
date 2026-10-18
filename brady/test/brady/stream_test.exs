defmodule Brady.HTTP.StreamTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Brady.HTTP.Stream

  @spec source(binary(), (Brady.Transport.t() -> term())) :: term()
  defp source(bytes, fun), do: source_fragments([bytes], fun)

  @spec source_fragments([binary()], (Brady.Transport.t() -> result)) :: result
        when result: term()
  defp source_fragments(parts, fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        send(parent, {:source_ready, self()})
        Enum.each(parts, fn bytes -> :ok = :gen_tcp.send(socket, bytes) end)
        :gen_tcp.close(socket)
      end)

    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    sender = server.pid
    assert_receive {:source_ready, ^sender}, 2000

    try do
      fun.({:tcp, client})
    after
      :gen_tcp.close(client)
      :gen_tcp.close(listener)
      Task.await(server)
    end
  end

  test "large fixed bodies reach a slow sink in bounded chunks" do
    bytes = :binary.copy("a", 1_000_000)
    parent = self()

    source(bytes, fn socket ->
      assert {:ok, "", 1_000_000} =
               Stream.body(socket, {:length, byte_size(bytes)}, "", fn chunk ->
                 assert byte_size(chunk) <= 65_536
                 send(parent, {:chunk, chunk})
                 :ok
               end)
    end)

    assert byte_size(collect([])) == byte_size(bytes)
  end

  test "chunk framing is validated and extensions/trailers are not forwarded" do
    parent = self()

    source("4;extension=secret\r\ndata\r\n0\r\nX-Trailer: secret\r\n\r\n", fn socket ->
      assert {:ok, "", 4} =
               Stream.body(socket, :chunked, "", fn chunk ->
                 send(parent, {:chunk, chunk})
                 :ok
               end)
    end)

    assert collect([]) == "4\r\ndata\r\n0\r\n\r\n"
  end

  test "early close and malformed chunk framing are failures" do
    source("short", fn socket ->
      assert {:error, :closed} = Stream.body(socket, {:length, 10}, "", fn _ -> :ok end)
    end)

    source("1\r\naXX", fn socket ->
      assert {:error, :invalid_http} = Stream.body(socket, :chunked, "", fn _ -> :ok end)
    end)
  end

  # @cc [owner:ghuntley,label:verification] chunked-parser-input-partitions
  # Generated initial buffers and socket-write partitions MUST preserve exact
  # decoded payload/count and trailer markers. Write boundaries MUST NOT be
  # presented as guaranteed TCP recv boundaries or cache publication evidence.
  property "decoded chunk payload is independent of wire partition and framing" do
    chunks = draw("chunks", list_of(binary(max_length: 90000), min_length: 1, max_length: 4))
    trailer = draw("trailer", boolean())
    cuts = draw("cuts", list_of(integer(1..1024), min_length: 1, max_length: 6))
    buffered = draw("buffered", member_of([0, 1, 2, 7, 65535]))

    for {chunks, trailer, buffered} <- [
          {chunks, trailer, buffered},
          {[], false, 65_535},
          {[], true, 65_535},
          {["fixed"], true, 65_535}
        ] do
      chunks = Enum.reject(chunks, &(byte_size(&1) == 0))

      wire =
        IO.iodata_to_binary(
          Enum.map(chunks, fn part ->
            [Integer.to_string(byte_size(part), 16), ";synthetic-extension\r\n", part, "\r\n"]
          end) ++ [if(trailer, do: "0\r\nSet-Cookie: synthetic\r\n\r\n", else: "0\r\n\r\n")]
        )

      parent = self()
      expected = IO.iodata_to_binary(chunks)

      prefix_size = min(buffered, byte_size(wire))
      <<prefix::binary-size(^prefix_size), remaining::binary>> = wire
      # Separate writes may coalesce in TCP. The explicitly supplied prefix is
      # a deterministic parser-buffer boundary; recv boundaries remain native.
      fragments = partition(remaining, cuts ++ [65_536])
      assert IO.iodata_to_binary(fragments) == remaining

      source_fragments(fragments, fn socket ->
        assert {:ok, "", count} =
                 Stream.body(socket, :chunked, prefix, fn _ -> :ok end, fn
                   {:payload, bytes} ->
                     assert byte_size(bytes) <= 65_536
                     send(parent, {:chunk, bytes})
                     :ok

                   :trailers ->
                     send(parent, :trailers)
                     :ok
                 end)

        assert count == byte_size(expected)
      end)

      assert collect([]) == expected
      if trailer, do: assert_received(:trailers)
      refute_received(:trailers)

      source(binary_part(wire, 0, max(0, byte_size(wire) - 2)), fn socket ->
        assert {:error, _} = Stream.body(socket, :chunked, "", fn _ -> :ok end)
      end)
    end
  end

  @spec partition(binary(), [pos_integer()]) :: [binary()]
  defp partition(bytes, cuts), do: partition(bytes, cuts, cuts, [])

  @spec partition(binary(), [pos_integer()], [pos_integer()], [binary()]) :: [binary()]
  defp partition(<<>>, _, _, acc), do: Enum.reverse(acc)
  defp partition(bytes, [], cycle, acc), do: partition(bytes, cycle, cycle, acc)

  defp partition(bytes, [size | tail], cycle, acc) do
    length = min(size, byte_size(bytes))
    <<part::binary-size(^length), rest::binary>> = bytes
    partition(rest, tail, cycle, [part | acc])
  end

  @spec collect([binary()]) :: binary()
  defp collect(acc) do
    receive do
      {:chunk, bytes} -> collect([bytes | acc])
    after
      0 -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
