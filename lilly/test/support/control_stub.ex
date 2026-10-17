defmodule Lilly.Test.ControlStub do
  @moduledoc """
  Test-only Marshall control WebSocket for Lilly (ADR-0142), over loopback TCP.

  `start/1` takes a handler `(op, body -> {:reply, result} | :ignore)` that runs
  in its own process per request, so a test can block one request while others
  proceed on the same connection. `:ignore` never answers, as a lost reply.
  `connected/1` starts the client's control link and waits for its welcome.
  """

  alias OverallsProtocol.Control.Envelope
  alias OverallsProtocol.WebSocket.{Frame, Handshake}

  @type handler :: (String.t(), map() -> {:reply, {:ok, map()} | {:error, String.t()}} | :ignore)

  @doc "Listens on loopback and returns the port and the listener."
  @spec start(handler()) :: {:inet.port_number(), :gen_tcp.socket()}
  def start(handler) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    spawn(fn -> accept(listener, handler) end)
    {port, listener}
  end

  @doc "Starts the client's control link under the test supervisor and waits for its welcome."
  @spec connected(Lilly.Control.Client.t()) :: Lilly.Control.Client.t()
  def connected(client) do
    client = %{client | control: :"lilly_control_#{System.unique_integer([:positive])}"}
    ExUnit.Callbacks.start_supervised!({Lilly.Control.Link, client}, id: client.control)
    wait(client.control, 150)
    client
  end

  @spec wait(atom(), non_neg_integer()) :: :ok
  defp wait(control, 0), do: raise("control client #{control} never connected")

  defp wait(control, attempts) do
    if Process.whereis(control) && OverallsProtocol.Control.Client.ready?(control) do
      :ok
    else
      Process.sleep(20)
      wait(control, attempts - 1)
    end
  end

  @spec accept(:gen_tcp.socket(), handler()) :: :ok
  defp accept(listener, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        worker = spawn(fn -> receive(do: ({:socket, s} -> upgrade(s, handler))) end)
        :ok = :gen_tcp.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept(listener, handler)

      _ ->
        :ok
    end
  end

  @spec upgrade(:gen_tcp.socket(), handler()) :: :ok
  defp upgrade(socket, handler) do
    {:ok, head} = read_head(socket, <<>>)

    key =
      head
      |> String.split("\r\n")
      |> Enum.find_value(fn line ->
        case String.split(line, ": ", parts: 2) do
          [name, value] -> if String.downcase(name) == "sec-websocket-key", do: value
          _ -> nil
        end
      end)

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n" <>
          "sec-websocket-accept: #{Handshake.accept(key)}\r\n\r\n"
      )

    :ok = :inet.setopts(socket, active: :once)
    loop(socket, handler, <<>>)
  end

  @spec read_head(:gen_tcp.socket(), binary()) :: {:ok, binary()}
  defp read_head(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, _] ->
        {:ok, head}

      _ ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_head(socket, buffer <> data)
    end
  end

  @spec loop(:gen_tcp.socket(), handler(), binary()) :: :ok
  defp loop(socket, handler, buffer) do
    receive do
      {:tcp, ^socket, data} ->
        :ok = :inet.setopts(socket, active: :once)
        frames(socket, handler, buffer <> data)

      {:reply, id, result} ->
        send_message(socket, {:res, %{id: id, result: result}})
        loop(socket, handler, buffer)

      {:tcp_closed, ^socket} ->
        :ok
    end
  end

  @spec frames(:gen_tcp.socket(), handler(), binary()) :: :ok
  defp frames(socket, handler, buffer) do
    case Frame.decode(buffer, :server, OverallsProtocol.max_body() + 4_096) do
      {:ok, {:text, text}, rest} ->
        message(socket, handler, Envelope.decode(text))
        frames(socket, handler, rest)

      {:ok, {:close, _code, _reason}, _rest} ->
        :gen_tcp.close(socket)

      {:ok, _other, rest} ->
        frames(socket, handler, rest)

      :more ->
        loop(socket, handler, buffer)
    end
  end

  @spec message(:gen_tcp.socket(), handler(), {:ok, Envelope.message()} | {:error, term()}) ::
          :ok
  defp message(socket, _handler, {:ok, {:hello, %{service: "lilly"}}}) do
    send_message(
      socket,
      {:welcome, %{conn: "stub", heartbeat_ms: 5_000, limits: %{"in_flight" => 64}}}
    )
  end

  defp message(_socket, handler, {:ok, {:req, %{id: id, op: op, body: body}}}) do
    connection = self()

    spawn(fn ->
      case handler.(op, body) do
        {:reply, result} -> send(connection, {:reply, id, result})
        :ignore -> :ok
      end
    end)

    :ok
  end

  defp message(socket, _handler, {:ok, {:ping, n}}), do: send_message(socket, {:pong, n})
  defp message(_socket, _handler, _message), do: :ok

  @spec send_message(:gen_tcp.socket(), Envelope.message()) :: :ok
  defp send_message(socket, message) do
    {:ok, data} =
      Frame.encode(
        {:text, Envelope.encode(message)},
        :server,
        OverallsProtocol.max_body() + 4_096
      )

    _ = :gen_tcp.send(socket, data)
    :ok
  end
end
