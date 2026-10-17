defmodule Lilly.TerminalTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Lilly.Terminal.Vsock
  alias OverallsProtocol.Terminal, as: Codec

  @identity %{
    uds_path: "/tmp/lilly-terminal-test.sock",
    placement_id: "11111111-1111-4111-8111-111111111111",
    execution_epoch: 4,
    boot_challenge: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  }

  property "hello tags bind placement, epoch and key material" do
    check all(
            placement <- member_of(["placement-a", "placement-b"]),
            epoch <- member_of([1, 2]),
            max_runs: 20
          ) do
      identity = %{@identity | placement_id: placement, execution_epoch: epoch}
      nonce = :crypto.strong_rand_bytes(16)
      tag = Vsock.hello_tag(identity, nonce)
      assert byte_size(tag) == 32
      assert tag == Vsock.hello_tag(identity, nonce)
      assert tag != Vsock.hello_tag(%{@identity | execution_epoch: epoch + 1}, nonce)

      assert tag ==
               :crypto.mac(
                 :hmac,
                 :sha256,
                 :crypto.hash(:sha256, [identity.boot_challenge, "overalls-terminald-v1"]),
                 ["terminald-hello-v1", nonce, placement, Integer.to_string(epoch)]
               )
    end
  end

  test "stream is ready only after hello_response and reports loss immediately" do
    host_id = Lilly.UUID.generate()
    session_id = Lilly.UUID.generate()
    parent = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1000)
        {:ok, request} = receive_headers(socket, "")
        [_, key] = Regex.run(~r/sec-websocket-key:\s*([^\r]+)/i, request)
        accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ",
            accept,
            "\r\n\r\n"
          ])

        {:ok, _hello} = :gen_tcp.recv(socket, 0, 1000)
        send(parent, :hello_received)

        receive do
          :authenticate ->
            payload = Codec.encode_control_frame(%{type: :hello_response, interval_ms: 1000})
            :ok = :gen_tcp.send(socket, <<0x82, byte_size(payload), payload::binary>>)
        end

        receive do
          :disconnect -> :gen_tcp.close(socket)
        end
      end)

    client = %Lilly.Control.Client{
      base_url: "http://127.0.0.1:#{port}",
      host_id: host_id,
      token: String.duplicate("a", 80),
      machine_id: "machine",
      allow_insecure_loopback: true
    }

    log =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :host_id, :reason]], fn ->
        {:ok, stream} =
          Lilly.Terminal.Stream.start_link(client, %{session_id: session_id, epoch: 1}, self())

        assert_receive :hello_received, 1000
        refute Lilly.Terminal.Stream.ready?(stream)
        send(server.pid, :authenticate)
        assert_receive {:terminal_stream_ready, ^stream, true}, 1000
        assert Lilly.Terminal.Stream.ready?(stream)
        send(server.pid, :disconnect)
        assert_receive {:terminal_stream_ready, ^stream, false}, 1000
        refute Lilly.Terminal.Stream.ready?(stream)
        GenServer.stop(stream)
      end)

    assert log =~ "lilly.terminal_stream_lost"
    assert log =~ "reason=closed"
    Task.await(server)
    :gen_tcp.close(listener)
  end

  @spec receive_headers(:gen_tcp.socket(), binary()) :: {:ok, binary()} | {:error, atom()}
  defp receive_headers(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      {:ok, buffer}
    else
      case :gen_tcp.recv(socket, 0, 1000) do
        {:ok, bytes} -> receive_headers(socket, buffer <> bytes)
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
