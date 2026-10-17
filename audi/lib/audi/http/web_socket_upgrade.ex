defmodule Audi.HTTP.WebSocketUpgrade do
  @moduledoc "Validate both WebSocket handshakes before switching to the guarded relay."
  import Plug.Conn
  alias Audi.HTTP.{Headers, WebSocket}
  require Audi.Events
  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  # Bandit's WebSock default; the listener read_timeout is for HTTP requests.
  @idle_timeout 60_000

  @spec requested?(Plug.Conn.t()) :: boolean()
  def requested?(conn), do: get_req_header(conn, "upgrade") != []

  # @cc [owner:ghuntley,label:security] audi-websocket-dual-handshake
  # Upgrade MUST be GET with a valid client key/version and no request body.
  # The guest MUST prove a fresh proxy-generated key and select at most one
  # requested subprotocol. Extensions MUST NOT be negotiated across this relay.
  # Handshake headers and sizes are bounded; only sanitized guest headers reach
  # the client. Successful upgrade retains socket ownership and lease renewal.
  @spec call(Plug.Conn.t(), tuple(), map(), pid(), binary() | nil) :: Plug.Conn.t()
  def call(conn, {module, config}, grant, renewal, source_vm_id) do
    with true <- valid_client?(conn),
         {:ok, protocols} <- protocols(conn),
         {:ok, headers} <-
           Headers.request(conn.req_headers, %{
             host: conn.host,
             port: conn.port,
             remote_ip: conn.remote_ip,
             user_id: grant.user_id,
             source_vm_id: source_vm_id
           }),
         {:ok, socket} <- module.open(config, grant.binding) do
      result = handshake(conn, socket, headers, protocols, renewal, grant.binding)
      if result.state != :upgraded, do: :gen_tcp.close(socket)
      result
    else
      _ -> send_resp(conn, 400, "Invalid WebSocket upgrade\n")
    end
  end

  def call(conn, _, _, _, _), do: send_resp(conn, 503, "Service unavailable\n")

  defp handshake(conn, socket, headers, protocols, renewal, binding) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))
    expected = Base.encode64(:crypto.hash(:sha, key <> @guid))

    headers =
      Enum.reject(headers, fn {name, _} -> String.starts_with?(name, "sec-websocket-") end)

    headers =
      headers ++
        [
          {"connection", "Upgrade"},
          {"upgrade", "websocket"},
          {"sec-websocket-key", key},
          {"sec-websocket-version", "13"}
        ]

    headers =
      if protocols == [],
        do: headers,
        else: headers ++ [{"sec-websocket-protocol", Enum.join(protocols, ", ")}]

    path =
      conn.request_path <> if(conn.query_string == "", do: "", else: "?" <> conn.query_string)

    request = [
      "GET ",
      path,
      " HTTP/1.1\r\n",
      Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "\r\n"
    ]

    with :ok <-
           :inet.setopts(socket,
             active: false,
             packet: :http_bin,
             packet_size: 8192,
             send_timeout: 1000,
             send_timeout_close: true,
             buffer: 65_536
           ),
         :ok <- :gen_tcp.send(socket, request),
         {:ok, {:http_response, {1, 1}, 101, _}} <- :gen_tcp.recv(socket, 0, 2000),
         :ok <- :inet.setopts(socket, packet: :httph_bin),
         {:ok, response} <-
           read_headers(socket, [], 0, System.monotonic_time(:millisecond) + 2000),
         true <- header(response, "sec-websocket-accept") == [expected],
         true <-
           tokens(response, "upgrade") == ["websocket"] and
             "upgrade" in tokens(response, "connection"),
         [] <- header(response, "sec-websocket-extensions"),
         selected = header(response, "sec-websocket-protocol"),
         true <- selected == [] or (length(selected) == 1 and hd(selected) in protocols),
         {:ok, clean} <- Headers.response(response),
         :ok <- :inet.setopts(socket, packet: :raw, packet_size: 0) do
      clean = Enum.reject(clean, fn {name, _} -> String.starts_with?(name, "sec-websocket-") end)

      clean =
        if selected == [], do: clean, else: clean ++ [{"sec-websocket-protocol", hd(selected)}]

      conn = delete_resp_header(conn, "connection")
      conn = %{conn | resp_headers: conn.resp_headers ++ clean}

      Audi.Events.emit("audi.websocket_upgraded",
        host_id: binding.host_id,
        vm_id: binding.vm_id,
        placement_id: binding.placement_id,
        session_id: binding.session_id,
        execution_epoch: binding.execution_epoch,
        generation: binding.generation
      )

      # @cc [owner:ghuntley,label:recovery] audi-websocket-idle-timeout
      # The relay MUST carry its own client idle timeout. Without one, Thousand
      # Island applies the listener's 5 s HTTP read_timeout to every WebSocket
      # read and Bandit closes a quiet browser socket with 1002, which a client
      # with a 5 s keepalive (the editor's extension host) races. Authority
      # stays with the lease guard; this bounds only an idle client.
      upgrade_adapter(
        conn,
        :websocket,
        {WebSocket, %{socket: socket, renewal: renewal, binding: binding},
         [compress: false, timeout: @idle_timeout]}
      )
    else
      _ -> send_resp(conn, 502, "WebSocket upstream unavailable\n")
    end
  end

  defp read_headers(socket, acc, size, deadline) when length(acc) <= 64 and size <= 65_536 do
    case :gen_tcp.recv(socket, 0, max(deadline - System.monotonic_time(:millisecond), 0)) do
      {:ok, :http_eoh} ->
        {:ok, Enum.reverse(acc)}

      {:ok, {:http_header, _, name, _, value}} ->
        name = name |> to_string() |> String.downcase()

        read_headers(
          socket,
          [{name, value} | acc],
          size + byte_size(name) + byte_size(value),
          deadline
        )

      _ ->
        :error
    end
  end

  defp read_headers(_, _, _, _), do: :error

  defp valid_client?(conn) do
    conn.method == "GET" and tokens(conn.req_headers, "upgrade") == ["websocket"] and
      "upgrade" in tokens(conn.req_headers, "connection") and
      get_req_header(conn, "sec-websocket-version") == ["13"] and
      get_req_header(conn, "content-length") in [[], ["0"]] and
      get_req_header(conn, "transfer-encoding") == [] and
      key?(get_req_header(conn, "sec-websocket-key"))
  end

  defp key?([key]) do
    case Base.decode64(key) do
      {:ok, bytes} when byte_size(bytes) == 16 -> Base.encode64(bytes) == key
      _ -> false
    end
  end

  defp key?(_), do: false

  defp protocols(conn) do
    values =
      for value <- get_req_header(conn, "sec-websocket-protocol"),
          token <- String.split(value, ","),
          do: String.trim(token)

    if length(values) <= 16 and length(Enum.uniq(values)) == length(values) and
         Enum.all?(
           values,
           &(byte_size(&1) in 1..128 and Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, &1))
         ), do: {:ok, values}, else: :error
  end

  defp header(headers, key), do: for({^key, value} <- headers, do: value)

  defp tokens(headers, key),
    do:
      for(
        value <- header(headers, key),
        token <- String.split(String.downcase(value), ","),
        do: String.trim(token)
      )
end
