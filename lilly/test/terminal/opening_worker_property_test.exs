defmodule Lilly.Terminal.OpeningWorkerPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Lilly.Terminal.Stream
  alias OverallsProtocol.Terminal, as: Codec
  alias OverallsProtocol.WebSocket.{Frame, Handshake}

  # @cc [owner:ghuntley,label:verification] opening-worker-observed-death
  # Worker death MUST follow a peer-observed real opening request. A fresh
  # request MUST follow death without fabricated completion or readiness.
  # This loopback test MUST NOT claim TLS, guest or native isolation coverage.
  property "a killed opening worker retires its attempt and permits a fresh dial" do
    check all(deaths <- integer(1..3), max_runs: 3, max_shrinking_steps: 0) do
      for shutdown <- [:orderly, :killed] do
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(listener)

        client = %Lilly.Control.Client{
          base_url: "http://127.0.0.1:#{port}",
          host_id: Lilly.UUID.generate(),
          token: String.duplicate("a", 80),
          machine_id: "fixture",
          allow_insecure_loopback: true
        }

        # Gate the initial attempt until tracing is installed. init's connect
        # message is processed while opening is occupied, then a barrier retires it.
        initial = %{
          client: client,
          session: %{session_id: Lilly.UUID.generate(), epoch: 1},
          runtime: self(),
          websocket: nil,
          opening: make_ref(),
          phase: :disconnected,
          buffer: <<>>,
          channels: %{},
          guests: %{},
          next_channel: 1,
          backoff: 1
        }

        {:ok, stream} = GenServer.start_link(Stream, initial)

        try do
          refute Stream.ready?(stream)
          :sys.replace_state(stream, &%{&1 | opening: nil})
          :erlang.trace(stream, true, [:procs])
          send(stream, :connect)

          for _ <- 1..deaths do
            assert_receive {:trace, ^stream, :spawn, worker, _}, 2_000
            {:ok, socket} = :gen_tcp.accept(listener, 2_000)

            try do
              assert {:ok, head} = read_head(socket, <<>>)
              # Check only a boolean so credentials never enter assertion output.
              assert String.starts_with?(head, "GET /api/provisioners/v4/stream ")
              refute Stream.ready?(stream)
              monitor = Process.monitor(worker)
              Process.exit(worker, :kill)
              assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
              assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
            after
              :gen_tcp.close(socket)
            end
          end

          # Authenticate the successor with the original exact session hello.
          assert_receive {:trace, ^stream, :spawn, _worker, _}, 2_000
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)

          try do
            assert {:ok, head} = read_head(socket, <<>>)
            [_, key] = Regex.run(~r/sec-websocket-key:\s*([^\r]+)/i, head)

            :ok =
              :gen_tcp.send(socket, [
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ",
                Handshake.accept(key),
                "\r\n\r\n"
              ])

            {:ok, {:binary, hello}, <<>>} = read_frame(socket, <<>>)
            assert {:ok, %{channel: 0, message: message}} = Codec.decode_frame(hello)

            assert message == %{
                     type: :hello,
                     host_id: client.host_id,
                     session_id: initial.session.session_id,
                     epoch: initial.session.epoch
                   }

            refute Stream.ready?(stream)
            reply = Codec.encode_control_frame(%{type: :hello_response, interval_ms: 1_000})
            {:ok, wire} = Frame.encode({:binary, reply}, :server, 262_158)
            :ok = :gen_tcp.send(socket, wire)
            assert_receive {:terminal_stream_ready, ^stream, true}, 1_000
            assert Stream.ready?(stream)
          after
            :gen_tcp.close(socket)
          end

          assert_receive {:terminal_stream_ready, ^stream, false}, 1_000
          assert_receive {:trace, ^stream, :spawn, worker, _}, 2_000
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)

          try do
            assert {:ok, _head} = read_head(socket, <<>>)
            refute Stream.ready?(stream)
            monitor = Process.monitor(worker)

            case shutdown do
              :orderly ->
                GenServer.stop(stream)

              :killed ->
                Process.unlink(stream)
                Process.exit(stream, :kill)
            end

            assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
            assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
          after
            :gen_tcp.close(socket)
          end
        after
          if Process.alive?(stream), do: GenServer.stop(stream)
          :gen_tcp.close(listener)
        end
      end
    end
  end

  @spec read_frame(:gen_tcp.socket(), binary()) ::
          {:ok, Frame.frame(), binary()} | {:error, atom()}
  defp read_frame(socket, buffer) do
    case Frame.decode(buffer, :server, 262_158) do
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
