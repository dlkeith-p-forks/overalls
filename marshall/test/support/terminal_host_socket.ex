defmodule Marshall.TerminalHostSocket do
  @moduledoc false
  @behaviour Plug
  import ExUnit.Assertions

  alias Marshall.TerminalAttachmentSocket, as: Socket

  @type options :: %{observer: pid()}

  @impl true
  @spec init(options()) :: options()
  def init(options), do: options

  # @cc [owner:ghuntley,label:verification] host-socket-real-process-boundary
  # This loopback fixture MUST execute the production credential/identity API
  # and HostStream in Bandit's upgraded process. Only HTTPS transport is supplied
  # synthetically; this fixture MUST NOT establish TLS or native host behavior.
  @impl true
  @spec call(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def call(conn, options) do
    send(options.observer, {:host_socket_process, self()})
    MarshallWeb.ProvisionerAPI.call(%{conn | scheme: :https}, [])
  end

  @spec connect(pos_integer(), String.t()) :: Socket.t()
  def connect(port, token) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)

    try do
      :ok = :inet.setopts(socket, packet: :http_bin)

      :ok =
        :gen_tcp.send(socket, [
          "GET /api/provisioners/v4/stream HTTP/1.1\r\nHost: localhost\r\n",
          "Authorization: Lilly ",
          token,
          "\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n",
          "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        ])

      assert {:ok, {:http_response, _, 101, _}} = :gen_tcp.recv(socket, 0, 2000)
      headers(socket)
      :ok = :inet.setopts(socket, packet: :raw)
      assert_receive {:host_socket_process, process}, 2000
      %{socket: socket, process: process, monitor: Process.monitor(process)}
    catch
      kind, reason ->
        :gen_tcp.close(socket)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @spec send_binary(Socket.t(), binary()) :: :ok | {:error, atom()}
  def send_binary(client, bytes) when byte_size(bytes) < 4096 do
    length = byte_size(bytes)
    prefix = if length < 126, do: <<length::7>>, else: <<126::7, length::16>>
    :gen_tcp.send(client.socket, [<<1::1, 0::3, 2::4, 1::1, prefix::bitstring, 0::32>>, bytes])
  end

  @spec headers(:gen_tcp.socket()) :: :ok
  defp headers(socket) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, :http_eoh} -> :ok
      {:ok, {:http_header, _, _, _, _}} -> headers(socket)
    end
  end
end
