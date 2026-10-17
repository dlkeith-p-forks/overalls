defmodule OverallsProtocol.WebSocket.Connection do
  @moduledoc """
  A client WebSocket owned by the calling process.

  The handshake is synchronous and bounded. Afterwards the socket runs in
  `active: :once` mode: the owner passes each transport message to `stream/2`,
  which decodes complete frames, answers pings and re-arms delivery. Nothing
  polls.
  """

  alias OverallsProtocol.WebSocket.{Frame, Handshake}

  @enforce_keys [:socket, :transport, :limit]
  defstruct [:socket, :transport, :limit, buffer: <<>>]

  @type t :: %__MODULE__{
          socket: :ssl.sslsocket() | :gen_tcp.socket(),
          transport: :tls | :plain,
          limit: pos_integer(),
          buffer: binary()
        }
  @type option ::
          {:headers, Handshake.headers()}
          | {:cacertfile, String.t()}
          | {:allow_insecure_loopback, boolean()}
          | {:timeout, pos_integer()}
          | {:limit, pos_integer()}
          | {:activate, boolean()}
  @type open_error ::
          :invalid_configuration
          | :connection_failed
          | :handshake_failed
          | {:status, 100..599}

  # @cc [owner:ghuntley,label:security] websocket-origin-configuration
  # open/3 MUST require an HTTPS origin without userinfo, query or fragment,
  # or an explicitly permitted literal loopback HTTP test origin, and MUST
  # connect over IPv4 only. Credential headers are never echoed in errors.
  @doc "Connects and completes the opening handshake."
  @spec open(String.t(), String.t(), [option()]) :: {:ok, t()} | {:error, open_error()}
  def open(base_url, path, options \\ []) do
    timeout = Keyword.get(options, :timeout, 5_000)
    limit = Keyword.get(options, :limit, 1_048_576)

    with {:ok, uri} <- origin(base_url, options),
         {:ok, socket, transport} <- connect(uri, options, timeout) do
      key = Handshake.key()
      request = Handshake.request(uri.host, path, key, Keyword.get(options, :headers, []))
      connection = %__MODULE__{socket: socket, transport: transport, limit: limit}

      with :ok <- send_raw(connection, request),
           {:ok, rest} <- await_head(connection, key, deadline(timeout), <<>>),
           :ok <-
             if(Keyword.get(options, :activate, true), do: active_once(connection), else: :ok) do
        {:ok, %{connection | buffer: rest}}
      else
        error ->
          close_transport(connection)
          normalize(error)
      end
    end
  end

  @doc "Gives the transport to `pid`; it receives transport messages once activated."
  @spec handoff(t(), pid()) :: :ok | {:error, term()}
  def handoff(%{transport: :tls, socket: socket}, pid), do: :ssl.controlling_process(socket, pid)

  def handoff(%{transport: :plain, socket: socket}, pid),
    do: :gen_tcp.controlling_process(socket, pid)

  @doc "Arms delivery of the next transport message to the controlling process."
  @spec activate(t()) :: :ok | {:error, term()}
  def activate(connection), do: active_once(connection)

  @doc "Sends one frame (masked, as a client)."
  @spec send_frame(t(), Frame.frame()) :: :ok | {:error, atom()}
  def send_frame(connection, frame) do
    with {:ok, data} <- Frame.encode(frame, :client, connection.limit) do
      send_raw(connection, data)
    end
  end

  @doc """
  Feeds one transport message. Returns decoded data frames, `{:closed, conn}`
  when the transport ended, or `:unknown` for an unrelated message.
  """
  @spec stream(t(), term()) ::
          {:ok, t(), [Frame.frame()]} | {:closed, t()} | {:error, t(), atom()} | :unknown
  def stream(%{transport: :tls, socket: socket} = connection, {:ssl, socket, data}),
    do: received(connection, data)

  def stream(%{transport: :plain, socket: socket} = connection, {:tcp, socket, data}),
    do: received(connection, data)

  def stream(%{socket: socket} = connection, {closed, socket})
      when closed in [:ssl_closed, :tcp_closed],
      do: {:closed, connection}

  def stream(%{socket: socket} = connection, {error, socket, _reason})
      when error in [:ssl_error, :tcp_error],
      do: {:closed, connection}

  def stream(_connection, _message), do: :unknown

  @doc """
  Decodes frames already buffered, e.g. bytes that arrived together with the
  handshake response, without waiting for another transport message.
  """
  @spec pending(t()) :: {:ok, t(), [Frame.frame()]} | {:error, t(), atom()}
  def pending(connection) do
    case frames(connection, connection.buffer, []) do
      {:ok, rest, frames} -> {:ok, %{connection | buffer: rest}, frames}
      {:error, reason} -> {:error, connection, reason}
    end
  end

  @doc "Sends a close frame with `code` and releases the transport."
  @spec close(t(), non_neg_integer()) :: :ok
  def close(connection, code \\ 1000) do
    _ = send_frame(connection, {:close, code, <<>>})
    close_transport(connection)
  end

  # @cc [owner:ghuntley,label:security] websocket-tls-peer-identity
  # Credential-bearing WebSockets MUST verify the certificate chain and HTTPS
  # hostname and MUST send the origin hostname as SNI. A custom CA file
  # replaces only the trust roots, never peer or hostname verification.
  @doc "TLS client options for `host`."
  @spec tls_options(String.t(), keyword()) :: [:ssl.tls_client_option()]
  def tls_options(host, options) do
    trust =
      case Keyword.get(options, :cacertfile) do
        path when is_binary(path) -> [cacertfile: String.to_charlist(path)]
        nil -> [cacerts: :public_key.cacerts_get()]
      end

    trust ++
      [
        verify: :verify_peer,
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
        depth: 3
      ]
  end

  @spec origin(String.t(), keyword()) :: {:ok, URI.t()} | {:error, :invalid_configuration}
  defp origin(base_url, options) do
    with {:ok, uri} <- URI.new(base_url),
         true <- is_binary(uri.host) and uri.host != "",
         true <- uri.userinfo == nil and uri.query == nil and uri.fragment == nil,
         true <-
           uri.scheme == "https" or
             (uri.scheme == "http" and uri.host == "127.0.0.1" and
                Keyword.get(options, :allow_insecure_loopback, false)) do
      {:ok, uri}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  @spec connect(URI.t(), keyword(), pos_integer()) ::
          {:ok, :ssl.sslsocket() | :gen_tcp.socket(), :tls | :plain}
          | {:error, :connection_failed}
  defp connect(%URI{scheme: "https", host: host} = uri, options, timeout) do
    base = [
      :binary,
      :inet,
      active: false,
      packet: :raw,
      send_timeout: 5_000,
      send_timeout_close: true
    ]

    case :ssl.connect(
           String.to_charlist(host),
           uri.port || 443,
           base ++ tls_options(host, options),
           timeout
         ) do
      {:ok, socket} -> {:ok, socket, :tls}
      {:error, _} -> {:error, :connection_failed}
    end
  end

  defp connect(%URI{scheme: "http", host: host} = uri, _options, timeout) do
    base = [
      :binary,
      :inet,
      active: false,
      packet: :raw,
      send_timeout: 5_000,
      send_timeout_close: true
    ]

    case :gen_tcp.connect(String.to_charlist(host), uri.port || 80, base, timeout) do
      {:ok, socket} -> {:ok, socket, :plain}
      {:error, _} -> {:error, :connection_failed}
    end
  end

  @spec await_head(t(), String.t(), integer(), binary()) ::
          {:ok, binary()} | {:error, :handshake_failed | {:status, 100..599}}
  defp await_head(connection, key, deadline, buffer) do
    case Handshake.response(buffer, key) do
      :more ->
        case recv(connection, remaining(deadline)) do
          {:ok, data} -> await_head(connection, key, deadline, buffer <> data)
          {:error, _} -> {:error, :handshake_failed}
        end

      result ->
        result
    end
  end

  @spec received(t(), binary()) :: {:ok, t(), [Frame.frame()]} | {:error, t(), atom()}
  defp received(connection, data) do
    case frames(connection, connection.buffer <> data, []) do
      {:ok, rest, frames} ->
        connection = %{connection | buffer: rest}

        # A peer that closed right after its last frames cannot be re-armed;
        # keep those frames and end with a close so nothing is dropped.
        case active_once(connection) do
          :ok -> {:ok, connection, frames}
          {:error, _} -> {:ok, connection, frames ++ [{:close, nil, <<>>}]}
        end

      {:error, reason} ->
        {:error, connection, reason}
    end
  end

  @spec frames(t(), binary(), [Frame.frame()]) ::
          {:ok, binary(), [Frame.frame()]} | {:error, atom()}
  defp frames(connection, buffer, acc) do
    case Frame.decode(buffer, :client, connection.limit) do
      {:ok, {:ping, payload}, rest} ->
        _ = send_frame(connection, {:pong, payload})
        frames(connection, rest, acc)

      {:ok, {:pong, _payload}, rest} ->
        frames(connection, rest, acc)

      {:ok, frame, rest} ->
        frames(connection, rest, [frame | acc])

      :more ->
        {:ok, buffer, Enum.reverse(acc)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec active_once(t()) :: :ok | {:error, term()}
  defp active_once(%{transport: :tls, socket: socket}), do: :ssl.setopts(socket, active: :once)
  defp active_once(%{transport: :plain, socket: socket}), do: :inet.setopts(socket, active: :once)

  @spec recv(t(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  defp recv(%{transport: :tls, socket: socket}, timeout), do: :ssl.recv(socket, 0, timeout)
  defp recv(%{transport: :plain, socket: socket}, timeout), do: :gen_tcp.recv(socket, 0, timeout)

  @spec send_raw(t(), iodata()) :: :ok | {:error, atom()}
  defp send_raw(%{transport: :tls, socket: socket}, data), do: :ssl.send(socket, data)
  defp send_raw(%{transport: :plain, socket: socket}, data), do: :gen_tcp.send(socket, data)

  @spec close_transport(t()) :: :ok
  defp close_transport(%{transport: :tls, socket: socket}), do: :ssl.close(socket)
  defp close_transport(%{transport: :plain, socket: socket}), do: :gen_tcp.close(socket)

  @spec normalize(term()) :: {:error, open_error()}
  defp normalize({:error, {:status, _code} = status}), do: {:error, status}
  defp normalize(_error), do: {:error, :handshake_failed}

  @spec deadline(pos_integer()) :: integer()
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  @spec remaining(integer()) :: non_neg_integer()
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
