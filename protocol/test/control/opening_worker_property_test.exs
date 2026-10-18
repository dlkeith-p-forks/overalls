defmodule OverallsProtocol.Control.OpeningWorkerPropertyTest do
  use ExUnit.Case, async: false

  alias OverallsProtocol.Control.Client
  alias OverallsProtocol.Control.Envelope
  alias OverallsProtocol.WebSocket.{Frame, Handshake}

  # @cc [owner:ghuntley,label:verification] control-opening-observed-worker-loss
  # Worker death MUST follow an actual peer-observed handshake. Recovery MUST
  # create a new worker/request without making the client ready prematurely.
  # Plain loopback evidence MUST NOT establish domain authorization or TLS.
  for finite_case <- 1..3 do
    @finite_case finite_case
    @tag timeout: 60000
    test "opening worker death permits a fresh control handshake (" <>
           to_string(finite_case) <> ")" do
      deaths = @finite_case

      for shutdown <- [:orderly, :killed] do
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(listener)
        observer = self()
        reference = make_ref()

        {:ok, client} =
          Client.start_link(
            url: "http://127.0.0.1:#{port}",
            allow_insecure_loopback: true,
            service: "galileo",
            owner: observer,
            bind: fn -> %{"generation" => 1} end,
            credential: fn ->
              send(observer, {:opening_worker, reference, self()})
              {:ok, "fixture-token"}
            end
          )

        try do
          for _ <- 1..deaths do
            assert_receive {:opening_worker, ^reference, worker}, 4500
            {:ok, socket} = :gen_tcp.accept(listener, 1000)

            try do
              assert {:ok, _head} = read_head(socket, <<>>)
              refute Client.ready?(client)
              assert Client.request(client, "galileo.renew", %{}) == {:error, :disconnected}
              monitor = Process.monitor(worker)
              Process.exit(worker, :kill)
              assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1000
              assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
            after
              :gen_tcp.close(socket)
            end
          end

          assert_receive {:opening_worker, ^reference, _worker}, 4500
          {:ok, socket} = :gen_tcp.accept(listener, 1000)

          try do
            assert {:ok, head} = read_head(socket, <<>>)
            [_, key] = Regex.run(~r/sec-websocket-key:\s*([^\r]+)/i, head)

            :ok =
              :gen_tcp.send(socket, [
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ",
                Handshake.accept(key),
                "\r\n\r\n"
              ])

            {:ok, {:text, hello}, <<>>} = read_frame(socket, <<>>)

            assert Envelope.decode(hello) ==
                     {:ok,
                      {:hello, %{version: 1, service: "galileo", bind: %{"generation" => 1}}}}

            refute Client.ready?(client)

            welcome =
              Envelope.encode({:welcome, %{conn: "fixture", heartbeat_ms: 5000, limits: %{}}})

            {:ok, wire} = Frame.encode({:text, welcome}, :server, 1_048_576)
            :ok = :gen_tcp.send(socket, wire)
            assert_receive {:control, ^client, {:connected, _}}, 1000
            assert Client.ready?(client)
          after
            :gen_tcp.close(socket)
          end

          assert_receive {:control, ^client, {:disconnected, :lost}}, 1000
          assert_receive {:opening_worker, ^reference, worker}, 4500
          {:ok, socket} = :gen_tcp.accept(listener, 1000)

          try do
            assert {:ok, _head} = read_head(socket, <<>>)
            monitor = Process.monitor(worker)

            case shutdown do
              :orderly ->
                GenServer.stop(client)

              :killed ->
                Process.unlink(client)
                Process.exit(client, :kill)
            end

            assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1000
            assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
          after
            :gen_tcp.close(socket)
          end
        after
          if Process.alive?(client) do
            GenServer.stop(client)
          end

          :gen_tcp.close(listener)
        end
      end
    end
  end

  @spec read_frame(:gen_tcp.socket(), binary()) ::
          {:ok, Frame.frame(), binary()} | {:error, Frame.decode_error() | atom()}
  defp read_frame(socket, buffer) do
    case Frame.decode(buffer, :server, 1_048_576) do
      :more ->
        case :gen_tcp.recv(socket, 0, 1000) do
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
      case :gen_tcp.recv(socket, 0, 1000) do
        {:ok, bytes} -> read_head(socket, buffer <> bytes)
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
