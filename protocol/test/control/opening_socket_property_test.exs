defmodule OverallsProtocol.Control.OpeningSocketPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  alias OverallsProtocol.Control.Client
  alias OverallsProtocol.WebSocket.{Connection, Frame, Handshake}

  # @cc [owner:ghuntley,label:verification;recovery] control-opening-socket-retirement
  # Current worker socket custody MUST survive failure before/after handoff and
  # failed completion. A gated credential fixture uses the actual opening worker
  # and registration callback with a real passive loopback socket; it MUST NOT
  # be described as an ordinary credential callback or TLS/domain evidence.
  property "registered opening sockets retire on worker loss or failed completion" do
    check all(repetitions <- integer(1..3), max_runs: 2, max_shrinking_steps: 0) do
      for _ <- 1..repetitions,
          action <- [:kill_before_handoff, :kill_after_handoff, :failed_completion] do
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(listener)
        url = "http://127.0.0.1:#{port}"
        observer = self()
        reference = make_ref()

        {:ok, client} =
          Client.start_link(
            url: url,
            allow_insecure_loopback: true,
            service: "galileo",
            owner: observer,
            bind: fn -> %{} end,
            credential: fn ->
              send(observer, {:opening_worker, reference, self()})

              receive do
                {:prepare_candidate, ^reference, owner, attempt} ->
                  {:ok, connection} =
                    Connection.open(url, "/api/control/v1",
                      allow_insecure_loopback: true,
                      activate: false
                    )

                  assert GenServer.call(owner, {:opening_connection, make_ref(), connection}) ==
                           :stale

                  assert GenServer.call(owner, {:opening_connection, attempt, connection}) == :ok

                  if action != :kill_before_handoff do
                    assert Connection.handoff(connection, owner) == :ok
                  end

                  send(observer, {:candidate_registered, reference})

                  receive do
                    {:fail_candidate, ^reference} -> {:error, :fixture_failed}
                  end
              end
            end
          )

        try do
          assert_receive {:opening_worker, ^reference, worker}, 1_000
          {attempt, ^worker, _monitor} = :sys.get_state(client).opening
          send(worker, {:prepare_candidate, reference, client, attempt})
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
            assert %Connection{} = :sys.get_state(client).opening_connection
            refute Client.ready?(client)
            assert Client.request(client, "galileo.renew", %{}) == {:error, :disconnected}
            monitor = Process.monitor(worker)
            reason = if action == :failed_completion, do: :normal, else: :killed

            if action == :failed_completion do
              send(worker, {:fail_candidate, reference})
            else
              Process.exit(worker, :kill)
            end

            assert_receive {:DOWN, ^monitor, :process, ^worker, ^reason}, 1_000
            assert_retired(socket)
            assert Client.status(client) == {:disconnected, :lost}
            assert :sys.get_state(client).opening_connection == nil
          after
            :gen_tcp.close(socket)
          end
        after
          if Process.alive?(client), do: GenServer.stop(client)
          :gen_tcp.close(listener)
        end
      end
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
