defmodule Lilly.Terminal.OpeningSocketPropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Lilly.Terminal.Stream
  alias OverallsProtocol.WebSocket.{Connection, Frame, Handshake}

  @type action :: :kill_before_handoff | :kill_after_handoff | :failed_completion

  # @cc [owner:ghuntley,label:verification;recovery] terminal-opening-socket-retirement
  # Registered socket custody MUST survive worker loss before/after handoff and
  # failed completion. A scripted worker is installed with real stream-owned
  # links/monitors; the registration/retirement callbacks and passive sockets
  # are real. This MUST NOT claim production dial reach, TLS or native guests.
  property "registered opening sockets retire on worker loss or failed completion",
    test_cases: 100 do
    repetitions = draw("repetitions", integer(1..3))

    for _ <- 1..repetitions,
        action <- [:kill_before_handoff, :kill_after_handoff, :failed_completion] do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      url = "http://127.0.0.1:#{port}"
      observer = self()
      reference = make_ref()

      client = %Lilly.Control.Client{
        base_url: url,
        host_id: Lilly.UUID.generate(),
        token: String.duplicate("a", 80),
        machine_id: "fixture",
        allow_insecure_loopback: true
      }

      initial = %{
        client: client,
        session: %{session_id: Lilly.UUID.generate(), epoch: 1},
        runtime: self(),
        websocket: nil,
        opening: make_ref(),
        phase: :disconnected,
        buffer: <<>>,
        android_channels: %{},
        channels: %{},
        guests: %{},
        next_channel: 1,
        backoff: 1
      }

      {:ok, stream} = GenServer.start_link(Stream, initial)

      try do
        refute Stream.ready?(stream)

        state =
          :sys.replace_state(stream, fn state ->
            owner = self()

            {worker, monitor} =
              :erlang.spawn_opt(
                fn -> fixture_worker(owner, observer, reference, url, action) end,
                [:link, :monitor]
              )

            %{state | opening: {reference, worker, monitor}}
          end)

        {^reference, worker, _monitor} = state.opening
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)

        try do
          assert {:ok, head} = read_head(socket, <<>>)
          [_, key] = Regex.run(~r/sec-websocket-key:\s*([^\r]+)/i, head)

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ",
              Handshake.accept(key),
              "\r\n\r\n"
            ])

          assert_receive {:candidate_registered, ^reference}, 1_000
          assert %Connection{} = :sys.get_state(stream).opening_connection
          refute Stream.ready?(stream)
          monitor = Process.monitor(worker)
          reason = if action == :failed_completion, do: :normal, else: :killed

          if action == :failed_completion do
            send(worker, :fail_candidate)
          else
            Process.exit(worker, :kill)
          end

          assert_receive {:DOWN, ^monitor, :process, ^worker, ^reason}, 1_000
          assert_retired(socket)
          assert :sys.get_state(stream).opening_connection == nil
          refute Stream.ready?(stream)
        after
          :gen_tcp.close(socket)
        end
      after
        if Process.alive?(stream), do: GenServer.stop(stream)
        :gen_tcp.close(listener)
      end
    end
  end

  @spec fixture_worker(pid(), pid(), reference(), String.t(), action()) :: :ok
  defp fixture_worker(owner, observer, reference, url, action) do
    {:ok, connection} =
      Connection.open(url, "/api/provisioners/v4/stream",
        allow_insecure_loopback: true,
        activate: false
      )

    assert GenServer.call(owner, {:opening_connection, make_ref(), connection}) == :stale
    assert GenServer.call(owner, {:opening_connection, reference, connection}) == :ok
    if action != :kill_before_handoff, do: assert(Connection.handoff(connection, owner) == :ok)
    send(observer, {:candidate_registered, reference})

    receive do
      :fail_candidate ->
        send(owner, {:stream_opened, reference, {:error, :fixture_failed}})
        :ok
    end
  end

  @spec assert_retired(:gen_tcp.socket()) :: :ok
  defp assert_retired(socket) do
    case read_frame(socket, <<>>) do
      {:error, :closed} ->
        :ok

      {:ok, {:close, 1000, <<>>}, <<>>} ->
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
        :ok

      _ ->
        flunk("unadopted opening socket did not retire")
    end
  end

  @spec read_frame(:gen_tcp.socket(), binary()) ::
          {:ok, Frame.frame(), binary()} | {:error, Frame.decode_error() | atom()}
  defp read_frame(socket, buffer) do
    case Frame.decode(buffer, :server, 1_048_576) do
      :more ->
        case :gen_tcp.recv(socket, 0, 1_000) do
          {:ok, bytes} -> read_frame(socket, buffer <> bytes)
          {:error, reason} -> {:error, reason}
        end

      result ->
        result
    end
  end

  @spec read_head(:gen_tcp.socket(), binary()) :: {:ok, binary()} | {:error, atom()}
  defp read_head(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      {:ok, buffer}
    else
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, bytes} -> read_head(socket, buffer <> bytes)
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
