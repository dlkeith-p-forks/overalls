defmodule Marshall.TerminalAttachmentSocket do
  @moduledoc false
  @behaviour Plug
  import ExUnit.Assertions

  @type t :: %{socket: :gen_tcp.socket(), process: pid(), monitor: reference()}
  @type options :: %{actor: Marshall.Accounts.User.t(), token: String.t(), observer: pid()}

  @impl true
  @spec init(options()) :: options()
  def init(options), do: options

  # @cc [owner:ghuntley,label:verification] attachment-real-websock-lifetime
  # The fixture MUST use the production terminal endpoint and Viewer inside
  # Bandit's actual upgraded connection process. Only upstream browser-session
  # authentication is supplied by the fixture; login/ticket/terminal authority
  # MUST still execute against the SQL sandbox. No callback may run after stop.
  @impl true
  def call(conn, options) do
    send(options.observer, {:attachment_process, self()})

    conn
    |> Plug.Conn.fetch_query_params()
    |> Plug.Test.init_test_session(%{"user_token" => options.token})
    |> Plug.Conn.assign(:current_user, options.actor)
    |> MarshallWeb.TerminalSocket.call([])
  end

  @spec connect(pos_integer(), String.t(), non_neg_integer()) :: t()
  def connect(port, ticket, cursor) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

    try do
      :ok = :inet.setopts(socket, packet: :http_bin)

      request = [
        "GET /api/terminal/v1/viewer/socket?",
        URI.encode_query(%{ticket: ticket, cursor: cursor, cols: 91, rows: 31}),
        " HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n",
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
      ]

      :ok = :gen_tcp.send(socket, request)
      assert {:ok, {:http_response, _, 101, _}} = :gen_tcp.recv(socket, 0, 2000)
      headers(socket)
      :ok = :inet.setopts(socket, packet: :raw)
      assert_receive {:attachment_process, process}, 2000
      %{socket: socket, process: process, monitor: Process.monitor(process)}
    catch
      kind, reason ->
        :gen_tcp.close(socket)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @spec send_frame(t(), 1 | 2 | 8 | 9, binary()) :: :ok | {:error, atom()}
  def send_frame(client, opcode, bytes) when byte_size(bytes) < 126 do
    # RFC6455 requires a client mask; zero is a legal mask for disposable data.
    :gen_tcp.send(
      client.socket,
      <<1::1, 0::3, opcode::4, 1::1, byte_size(bytes)::7, 0::32, bytes::binary>>
    )
  end

  @spec frame(t(), timeout()) :: {non_neg_integer(), binary()} | {:error, atom()}
  def frame(client, timeout \\ 3000) do
    case :gen_tcp.recv(client.socket, 2, timeout) do
      {:ok, <<1::1, 0::3, opcode::4, 0::1, length::7>>} ->
        length = if length == 126, do: extended_length(client.socket), else: length
        assert length < 4096
        bytes = if length == 0, do: "", else: receive_bytes(client.socket, length)
        {opcode, bytes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec barrier(t()) :: :ok
  def barrier(client) do
    assert :ok = send_frame(client, 9, "barrier")
    assert {10, "barrier"} = frame(client)
    :ok
  end

  @spec closed(t()) :: :ok
  def closed(client) do
    # The periodic authority backstop runs every five seconds, and viewer
    # heartbeats may arrive first; skip them while waiting for the close.
    assert {8, _} = close_frame(client, System.monotonic_time(:millisecond) + 8_000)
    _ = send_frame(client, 8, <<1000::16>>)
    monitor = client.monitor
    process = client.process
    assert_receive {:DOWN, ^monitor, :process, ^process, _}, 3000
    :gen_tcp.close(client.socket)
    :ok
  end

  @spec disconnect(t()) :: :ok
  def disconnect(client) do
    :gen_tcp.close(client.socket)
    monitor = client.monitor
    process = client.process
    assert_receive {:DOWN, ^monitor, :process, ^process, _}, 3000
    :ok
  end

  @spec dispose(t()) :: :ok
  def dispose(client) do
    :gen_tcp.close(client.socket)
    Process.demonitor(client.monitor, [:flush])
    :ok
  end

  @spec headers(:gen_tcp.socket()) :: :ok
  defp headers(socket) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, :http_eoh} -> :ok
      {:ok, {:http_header, _, _, _, _}} -> headers(socket)
    end
  end

  @spec extended_length(:gen_tcp.socket()) :: non_neg_integer()
  defp extended_length(socket) do
    <<length::16>> = receive_bytes(socket, 2)
    length
  end

  @spec receive_bytes(:gen_tcp.socket(), pos_integer()) :: binary()
  defp receive_bytes(socket, length) do
    {:ok, bytes} = :gen_tcp.recv(socket, length, 3000)
    bytes
  end

  @spec close_frame(t(), integer()) :: {non_neg_integer(), binary()} | {:error, term()}
  defp close_frame(client, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    case frame(client, remaining) do
      {1, ~s({"op":"heartbeat"})} -> close_frame(client, deadline)
      other -> other
    end
  end
end
