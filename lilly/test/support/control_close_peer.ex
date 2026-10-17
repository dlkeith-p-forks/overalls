defmodule Lilly.Test.ControlClosePeer do
  @moduledoc "Owned verified-TLS peer exposing only request IDs and closed operation names."
  alias OverallsProtocol.Control.Envelope
  alias OverallsProtocol.WebSocket.{Frame, Handshake}

  @type command ::
          {:reply, pos_integer(), {:ok, map()} | {:error, String.t()}} | {:close, 4000..4008}

  # @cc [owner:ghuntley,label:verification;security] lilly-close-peer-observation
  # Observations MUST contain only synthetic connection ownership, request IDs and
  # closed operation names; credentials and request payloads MUST NOT escape.
  @spec serve(:ssl.sslsocket(), pid(), reference()) :: :ok
  def serve(listener, owner, reference) do
    {:ok, transport} = :ssl.transport_accept(listener, 5_000)
    {:ok, socket} = :ssl.handshake(transport, 5_000)

    try do
      head = read_head(socket, <<>>)
      key = header(head, "sec-websocket-key")

      :ok =
        :ssl.send(
          socket,
          "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: #{Handshake.accept(key)}\r\n\r\n"
        )

      :ok = :ssl.setopts(socket, active: :once)
      loop(socket, owner, reference, <<>>)
    after
      :ssl.close(socket)
    end
  end

  @spec read_head(:ssl.sslsocket(), binary()) :: binary()
  defp read_head(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, _] ->
        head

      _ ->
        {:ok, data} = :ssl.recv(socket, 0, 5_000)
        read_head(socket, buffer <> data)
    end
  end

  @spec header(binary(), String.t()) :: String.t()
  defp header(head, wanted) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ": ", parts: 2) do
        [name, value] -> if String.downcase(name) == wanted, do: value
        _ -> nil
      end
    end)
    |> then(fn
      value when is_binary(value) -> value
      _ -> raise "missing fixture upgrade key"
    end)
  end

  @spec loop(:ssl.sslsocket(), pid(), reference(), binary()) :: :ok
  defp loop(socket, owner, reference, buffer) do
    receive do
      {:ssl, ^socket, bytes} ->
        :ok = :ssl.setopts(socket, active: :once)
        frames(socket, owner, reference, buffer <> bytes)

      {:reply, id, result} ->
        send_message(socket, {:res, %{id: id, result: result}})
        loop(socket, owner, reference, buffer)

      {:close, code} when code in 4000..4008 ->
        {:ok, data} = Frame.encode({:close, code, <<>>}, :server, 125)
        :ok = :ssl.send(socket, data)
        loop(socket, owner, reference, buffer)

      {:ssl_closed, ^socket} ->
        :ok
    after
      10_000 -> raise "fixture peer did not retire"
    end
  end

  @spec frames(:ssl.sslsocket(), pid(), reference(), binary()) :: :ok
  defp frames(socket, owner, reference, buffer) do
    case Frame.decode(buffer, :server, OverallsProtocol.max_body() + 4_096) do
      {:ok, {:text, text}, rest} ->
        {:ok, message} = Envelope.decode(text)
        message(socket, owner, reference, message)
        frames(socket, owner, reference, rest)

      {:ok, {:close, _, _}, _} ->
        :ok

      {:ok, _, rest} ->
        frames(socket, owner, reference, rest)

      :more ->
        loop(socket, owner, reference, buffer)
    end
  end

  @spec message(:ssl.sslsocket(), pid(), reference(), Envelope.message()) :: :ok
  defp message(socket, owner, reference, {:hello, %{service: "lilly"}}) do
    send_message(
      socket,
      {:welcome, %{conn: "fixture", heartbeat_ms: 5_000, limits: %{"in_flight" => 64}}}
    )

    send(owner, {:peer_welcomed, reference})
    :ok
  end

  defp message(_socket, owner, reference, {:req, %{id: id, op: op}})
       when op in ["lilly.sessions", "lilly.exchange"] do
    send(owner, {:peer_request, reference, id, op})
    :ok
  end

  defp message(socket, _owner, _reference, {:ping, counter}),
    do: send_message(socket, {:pong, counter})

  defp message(_socket, _owner, _reference, _message), do: :ok

  @spec send_message(:ssl.sslsocket(), Envelope.message()) :: :ok
  defp send_message(socket, message) do
    {:ok, data} =
      Frame.encode(
        {:text, Envelope.encode(message)},
        :server,
        OverallsProtocol.max_body() + 4_096
      )

    :ok = :ssl.send(socket, data)
  end
end
