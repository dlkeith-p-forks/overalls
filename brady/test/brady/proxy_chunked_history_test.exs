defmodule Brady.ProxyChunkedHistoryTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Brady.{Cache, Cache.Store, HTTP.Stream, Proxy}

  @type mode :: :complete | :trailer | :truncated | :malformed | :private | :overflow
  @type config :: %{
          destination_policy: [],
          socket_options: [],
          cache: pid(),
          resolver: (String.t() -> {:ok, [Brady.Destination.ipv4()]})
        }
  @type origin_state :: %{wire: [binary()], count: non_neg_integer()}

  # @cc [owner:ghuntley,label:verification;security] proxy-chunked-completion-composition
  # The real Proxy/parser/Cache path MUST publish only complete public payloads.
  # Trailer, malformed, truncated, private and append-overflow histories MUST
  # release reservations and remain misses on retry. Exact reusable bytes and
  # origin request counts MUST come from independent workload inputs.
  # Forwarded responses MUST preserve normalized chunk framing and decoded
  # payloads; invalid completion MUST NOT emit a terminal frame or extra reply.
  # Reused responses MUST deliver the exact unframed workload payload.
  # Empty destination policy MUST remain a loopback fixture override and MUST NOT
  # establish public destination admission, TLS, interception or guest isolation.
  property "chunked proxy histories reuse only complete public parser results" do
    chunks =
      draw(
        "chunks",
        list_of(binary(min_length: 2, max_length: 2048), min_length: 1, max_length: 4)
      )

    mode =
      draw("mode", member_of([:complete, :trailer, :truncated, :malformed, :private, :overflow]))

    cut = draw("cut", member_of([1, 2, 7, 31, 65536]))

    supervisor = Overalls.HegelFixtures.start_supervised!(Task.Supervisor)

    for {parts, outcome} <- [
          {chunks, mode},
          {[], :complete},
          {chunks, :complete},
          {chunks, :trailer},
          {chunks, :truncated},
          {chunks, :malformed},
          {chunks, :private},
          {chunks, :overflow}
        ] do
      history(supervisor, parts, outcome, cut)
    end
  end

  @spec history(pid(), [binary()], mode(), pos_integer()) :: :ok
  defp history(supervisor, chunks, mode, cut) do
    root =
      Path.join(System.tmp_dir!(), "brady-proxy-history-#{System.unique_integer([:positive])}")

    store_id = {:proxy_store, make_ref()}
    agent_id = {:proxy_origin, make_ref()}
    object = if mode == :overflow, do: 1, else: 100_000

    cache =
      start_supervised!(
        Supervisor.child_spec(
          {Store,
           root: root, limits: %{quota: 1_000_000, object: object, high: 900_000, low: 800_000}},
          id: store_id
        )
      )

    :ok = Store.observe(cache, 90, 100, true)
    expected = IO.iodata_to_binary(chunks)
    wire = response(chunks, mode)
    fragments = fragments(wire, [cut, 65_536])
    assert IO.iodata_to_binary(fragments) == wire

    counter =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> %{wire: fragments, count: 0} end}, id: agent_id)
      )

    {:ok, origin} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, origin_port}} = :inet.sockname(origin)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)

    config = %{
      destination_policy: [],
      socket_options: [],
      cache: cache,
      resolver: fn "origin.example" -> {:ok, [{127, 0, 0, 1}]} end
    }

    {:ok, origin_worker} =
      Task.Supervisor.start_child(supervisor, fn -> origin_loop(origin, counter) end)

    {:ok, proxy_worker} =
      Task.Supervisor.start_child(supervisor, fn -> proxy_loop(listener, origin_port, config) end)

    try do
      first = request(port, origin_port)
      assert :binary.match(first, "HTTP/1.1 200 OK\r\n") == {0, 17}
      terminated = mode not in [:truncated, :malformed]
      forwarded = canonical_body(chunks, terminated)
      assert [_, ^forwarded] = :binary.split(first, "\r\n\r\n")
      assert %{pending: 0, writers: 0} = Store.stats(cache)
      assert File.ls!(Path.join(root, "tmp")) == []

      cache_request = %{
        method: "GET",
        scheme: :http,
        host: "origin.example",
        port: origin_port,
        target: "/stream",
        headers: []
      }

      now = System.system_time(:second)

      if mode == :complete do
        assert %{objects: 1} = Store.stats(cache)
        size = byte_size(expected)
        assert {:hit, reader, _, 0, ^size} = Cache.lookup(cache, cache_request, now)
        parent = self()

        assert :ok =
                 Cache.stream(cache, reader, 0, size, fn bytes ->
                   send(parent, {:reused_payload, bytes})
                   :ok
                 end)

        assert collect([]) == expected
        assert :ok = Cache.close(cache, reader)
      else
        assert %{objects: 0, used: 0} = Store.stats(cache)
        assert :miss = Cache.lookup(cache, cache_request, now)
      end

      second = request(port, origin_port)
      assert :binary.match(second, "HTTP/1.1 200 OK\r\n") == {0, 17}

      if mode == :complete do
        assert [_, ^expected] = :binary.split(second, "\r\n\r\n")
      else
        assert [_, ^forwarded] = :binary.split(second, "\r\n\r\n")
      end

      count = Agent.get(counter, fn state -> state.count end)
      assert count == if(mode == :complete, do: 1, else: 2)
      assert %{pending: 0, readers: 0, writers: 0} = Store.stats(cache)
      assert Store.stats(cache).objects == if(mode == :complete, do: 1, else: 0)
      :ok
    after
      Task.Supervisor.terminate_child(supervisor, origin_worker)
      Task.Supervisor.terminate_child(supervisor, proxy_worker)
      :gen_tcp.close(origin)
      :gen_tcp.close(listener)
      stop_supervised(store_id)
      stop_supervised(agent_id)
      File.rm_rf!(root)
    end
  end

  @spec canonical_body([binary()], boolean()) :: binary()
  defp canonical_body(chunks, terminated) do
    # Independent workload framing excludes origin extensions/trailers. Invalid
    # completion forwards only already-complete chunk frames, never a new reply.
    frames =
      Enum.map(chunks, fn bytes ->
        [Integer.to_string(byte_size(bytes), 16), "\r\n", bytes, "\r\n"]
      end)

    IO.iodata_to_binary(frames ++ [if(terminated, do: "0\r\n\r\n", else: "")])
  end

  @spec response([binary()], mode()) :: binary()
  defp response(chunks, mode) do
    date = :httpd_util.rfc1123_date() |> List.to_string()
    privacy = if mode == :private, do: "private", else: "public"

    body =
      IO.iodata_to_binary(
        Enum.map(chunks, fn bytes ->
          [Integer.to_string(byte_size(bytes), 16), ";fixture\r\n", bytes, "\r\n"]
        end)
      )

    terminal =
      case mode do
        :trailer -> "0\r\nX-Fixture: fixed\r\n\r\n"
        :malformed -> "0\r\ninvalid-trailer\r\n\r\n"
        :truncated -> "0\r\n"
        _ -> "0\r\n\r\n"
      end

    "HTTP/1.1 200 OK\r\nDate: #{date}\r\nCache-Control: #{privacy}, max-age=600\r\nTransfer-Encoding: chunked\r\n\r\n" <>
      body <> terminal
  end

  @spec fragments(binary(), [pos_integer()]) :: [binary()]
  defp fragments(bytes, sizes), do: fragments(bytes, sizes, sizes, [])
  @spec fragments(binary(), [pos_integer()], [pos_integer()], [binary()]) :: [binary()]
  defp fragments(<<>>, _, _, acc), do: Enum.reverse(acc)
  defp fragments(bytes, [], cycle, acc), do: fragments(bytes, cycle, cycle, acc)

  defp fragments(bytes, [size | rest], cycle, acc) do
    take = min(size, byte_size(bytes))
    <<part::binary-size(^take), tail::binary>> = bytes
    fragments(tail, rest, cycle, [part | acc])
  end

  @spec origin_loop(:inet.socket(), pid()) :: :ok
  defp origin_loop(listener, counter) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, head, rest} = Stream.head({:tcp, socket}, :request)
        {:ok, _, _} = Stream.body({:tcp, socket}, head.body, rest, fn _ -> :ok end)

        parts =
          Agent.get_and_update(counter, fn state ->
            {state.wire, %{state | count: state.count + 1}}
          end)

        try do
          Enum.each(parts, fn bytes -> :ok = :gen_tcp.send(socket, bytes) end)
        after
          :gen_tcp.close(socket)
        end

        origin_loop(listener, counter)

      {:error, :closed} ->
        :ok
    end
  end

  @spec proxy_loop(:inet.socket(), pos_integer(), config()) :: :ok
  defp proxy_loop(listener, origin_port, config) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :ok =
          Proxy.serve({:tcp, socket}, {{127, 0, 0, 1}, origin_port}, :http, config, %{
            attribution: :resolved
          })

        proxy_loop(listener, origin_port, config)

      {:error, :closed} ->
        :ok
    end
  end

  @spec request(pos_integer(), pos_integer()) :: binary()
  defp request(port, origin_port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    try do
      :ok =
        :gen_tcp.send(
          socket,
          "GET /stream HTTP/1.1\r\nHost: origin.example:#{origin_port}\r\n\r\n"
        )

      receive_all(socket, [])
    after
      :gen_tcp.close(socket)
    end
  end

  @spec receive_all(:inet.socket(), [binary()]) :: binary()
  defp receive_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, bytes} -> receive_all(socket, [bytes | acc])
      {:error, :closed} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      {:error, _} -> flunk("Loopback proxy did not finish its bounded response")
    end
  end

  @spec collect([binary()]) :: binary()
  defp collect(acc) do
    receive do
      {:reused_payload, bytes} -> collect([bytes | acc])
    after
      0 -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
