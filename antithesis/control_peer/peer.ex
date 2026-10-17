defmodule OverallsAntithesis.ControlPeer do
  @moduledoc """
  A loopback WebSocket peer with an independent inventory of client wire frames.

  This peer tests the real OverallsProtocol.Control.Client state machine. It does
  not impersonate Marshall or establish a durable domain effect.
  """

  alias OverallsProtocol.Control.{Client, Envelope}
  alias OverallsProtocol.WebSocket.{Frame, Handshake}

  @type connection :: pid()
  @type observed :: {:req, %{id: non_neg_integer(), op: String.t(), body: map()}}

  # @cc [owner:ghuntley,label:verification] control-peer-wire-ledger
  # Only complete WebSocket request frames decoded from the peer socket count as
  # sent requests. A caller invocation or client pending-map entry MUST NOT be
  # substituted for wire observation.
  @spec start(pid()) :: {:ok, :inet.port_number(), pid()}
  def start(owner) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, :inet, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    acceptor = spawn_link(fn -> accept(listener, owner) end)
    {:ok, port, acceptor}
  end

  @spec client(:inet.port_number(), pid()) :: {:ok, pid()} | {:error, term()}
  def client(port, owner) do
    Client.start_link(
      url: "http://127.0.0.1:#{port}",
      allow_insecure_loopback: true,
      service: "galileo",
      credential: fn -> {:ok, "synthetic-loopback-only"} end,
      bind: fn -> %{"generation" => 1} end,
      owner: owner
    )
  end

  @spec welcome(connection(), map()) :: :ok
  def welcome(server, limits) do
    send(server, {:send, {:welcome, %{conn: "controlled", heartbeat_ms: 5_000, limits: limits}}})
    :ok
  end

  @spec response(connection(), non_neg_integer(), integer()) :: :ok
  def response(server, id, nonce) do
    send(server, {:send, {:res, %{id: id, result: {:ok, %{"nonce" => nonce}}}}})
    :ok
  end

  @spec drop(connection()) :: :ok
  def drop(server) do
    send(server, :drop)
    :ok
  end

  @spec barrier(connection(), non_neg_integer()) :: boolean()
  def barrier(server, nonce) do
    send(server, {:send, {:ping, nonce}})

    receive do
      {:wire, ^server, {:pong, ^nonce}} -> true
    after
      2_000 -> false
    end
  end

  @spec await_connection(pid(), non_neg_integer()) :: {:ok, pid()} | :unavailable
  def await_connection(_client, timeout \\ 3_000) do
    receive do
      {:peer_connected, server} ->
        with {:wire, ^server, {:hello, _}} <- await_hello(server, timeout) do
          {:ok, server}
        else
          _ -> :unavailable
        end
    after
      timeout -> :unavailable
    end
  end

  @spec await_ready(pid(), non_neg_integer()) :: boolean()
  def await_ready(client, timeout \\ 3_000) do
    receive do
      {:control, ^client, {:connected, _welcome}} -> true
    after
      timeout -> false
    end
  end

  @spec await_request(connection(), non_neg_integer()) ::
          {:ok, non_neg_integer(), integer()} | :unavailable
  def await_request(server, timeout \\ 3_000) do
    receive do
      {:wire, ^server, {:req, %{id: id, body: %{"nonce" => nonce}}}}
      when is_integer(id) and is_integer(nonce) ->
        {:ok, id, nonce}
    after
      timeout -> :unavailable
    end
  end

  @spec no_request?(connection()) :: boolean()
  def no_request?(server) do
    receive do
      {:wire, ^server, {:req, _}} -> false
    after
      0 -> true
    end
  end

  @spec await_disconnected(pid(), non_neg_integer()) :: boolean()
  def await_disconnected(client, timeout \\ 3_000) do
    receive do
      {:control, ^client, {:disconnected, _reason}} -> true
    after
      timeout -> false
    end
  end

  @spec await_hello(connection(), non_neg_integer()) ::
          {:wire, connection(), {:hello, map()}} | :unavailable
  defp await_hello(server, timeout) do
    receive do
      {:wire, ^server, {:hello, hello}} -> {:wire, server, {:hello, hello}}
    after
      timeout -> :unavailable
    end
  end

  @spec accept(:gen_tcp.socket(), pid()) :: :ok
  defp accept(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve(socket, owner)
        accept(listener, owner)

      {:error, _} ->
        :ok
    end
  end

  @spec serve(:gen_tcp.socket(), pid()) :: :ok
  defp serve(socket, owner) do
    with {:ok, head} <- read_head(socket, <<>>) do
      headers =
        head
        |> String.split("\r\n")
        |> tl()
        |> Enum.reduce(%{}, fn line, acc ->
          case :binary.split(line, ": ") do
            [key, value] -> Map.put(acc, String.downcase(key), value)
            _ -> acc
          end
        end)

      case headers["sec-websocket-key"] do
        key when is_binary(key) ->
          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: #{Handshake.accept(key)}\r\n\r\n"
            )

          send(owner, {:peer_connected, self()})
          loop(socket, owner, <<>>)

        _ ->
          :gen_tcp.close(socket)
      end
    else
      _ -> :gen_tcp.close(socket)
    end
  end

  @spec read_head(:gen_tcp.socket(), binary()) :: {:ok, binary()} | :error
  defp read_head(socket, buffer) when byte_size(buffer) <= 16_384 do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, _] ->
        {:ok, head}

      _ ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_head(socket, buffer <> data)
          _ -> :error
        end
    end
  end

  defp read_head(_socket, _buffer), do: :error

  @spec loop(:gen_tcp.socket(), pid(), binary()) :: :ok
  defp loop(socket, owner, buffer) do
    case Frame.decode(buffer, :server, 1_048_576) do
      {:ok, {:text, text}, rest} ->
        case Envelope.decode(text) do
          {:ok, message} -> send(owner, {:wire, self(), message})
          _ -> send(owner, {:peer_invalid_frame, self()})
        end

        loop(socket, owner, rest)

      {:ok, {:close, _code, _}, _rest} ->
        :gen_tcp.close(socket)

      {:ok, _other, rest} ->
        loop(socket, owner, rest)

      :more ->
        wait_or_read(socket, owner, buffer)

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end

  @spec wait_or_read(:gen_tcp.socket(), pid(), binary()) :: :ok
  defp wait_or_read(socket, owner, buffer) do
    receive do
      {:send, message} ->
        {:ok, data} = Frame.encode({:text, Envelope.encode(message)}, :server, 1_048_576)
        :ok = :gen_tcp.send(socket, data)
        loop(socket, owner, buffer)

      :drop ->
        :gen_tcp.close(socket)
    after
      10 ->
        case :gen_tcp.recv(socket, 0, 10) do
          {:ok, data} -> loop(socket, owner, buffer <> data)
          {:error, :timeout} -> loop(socket, owner, buffer)
          _ -> :ok
        end
    end
  end
end
