defmodule Audi.HTTP.Proxy do
  @moduledoc "Streaming HTTP through the placement-bound local connector."
  import Plug.Conn
  alias Audi.HTTP.{Authority, Browser, Headers, WebSocketUpgrade}
  alias Audi.Control.Client
  require Audi.Events

  @typep failure_phase ::
           :request_headers
           | :request_method
           | :connector
           | :initiate
           | :socket_options
           | :request
           | :upload_body
           | :upload_eof
           | :read_body
           | :recv
           | :response_headers
           | :downstream_body
           | :response_events
  @typep failure_reason :: :timeout | :closed | :protocol | :other

  # @cc [owner:ghuntley,label:security] audi-web-admission-before-bytes
  # Host selection MUST use the validated TLS origin. Fresh web authority and an
  # independent guard MUST precede guest connection. Browser sign-in is only for
  # missing private identity; public requests never require a browser redirect.
  # No credential, response or request may choose a connector address or module.
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, options) do
    client = Keyword.fetch!(options, :client)

    cookie =
      case Browser.credential(conn) do
        {:ok, cookie} -> cookie
        :error -> nil
      end

    with {:ok, label, app_port} <- Browser.target(conn.host, options[:zone]),
         {:ok, peer_token} <- peer_token(conn, label, app_port),
         {:ok, grant, source_vm_id} <-
           admit(client, label, app_port, cookie, peer_token),
         {:ok, renewal} <- Authority.start(client, grant) do
      Audi.Events.emit("audi.web_admitted",
        host_id: grant.binding.host_id,
        vm_id: grant.binding.vm_id,
        placement_id: grant.binding.placement_id,
        session_id: grant.binding.session_id,
        execution_epoch: grant.binding.execution_epoch,
        generation: grant.binding.generation
      )

      result =
        if WebSocketUpgrade.requested?(conn),
          do: WebSocketUpgrade.call(conn, options[:connector], grant, renewal, source_vm_id),
          else: forward(conn, options[:connector], grant, source_vm_id)

      unless result.state == :upgraded do
        Authority.finish(renewal)

        Audi.Events.emit("audi.web_closed",
          host_id: grant.binding.host_id,
          vm_id: grant.binding.vm_id,
          placement_id: grant.binding.placement_id,
          session_id: grant.binding.session_id,
          execution_epoch: grant.binding.execution_epoch,
          generation: grant.binding.generation
        )
      end

      result
    else
      {:error, :authentication_required} ->
        Audi.Events.emit("audi.web_denied", reason: :authentication_required)
        Browser.start(conn, client, options[:zone], options[:browser_origin])

      # @cc [owner:ghuntley,label:security] audi-web-refusal-class-boundary
      # An explicit membership or VM denial from the control plane MUST answer
      # 403; missing route, execution, gateway or stream authority MUST answer
      # 503. Neither class may forward request bytes or contact a guest, and
      # neither may silently start browser enrollment for an identified caller.
      {:error, :forbidden} ->
        Audi.Events.emit("audi.web_denied", reason: :forbidden)
        send_resp(conn, 403, "Access denied\n")

      {:error, :unauthorized} ->
        Audi.Events.emit("audi.web_denied", reason: :unauthorized)
        send_resp(conn, 503, "Service unavailable\n")

      {:error, :invalid_peer_token} ->
        send_resp(conn, 403, "Access denied\n")

      _ ->
        send_resp(conn, 503, "Service unavailable\n")
    end
  end

  # @cc [owner:ghuntley,label:security] audi-http-stream-framing
  # Mint MUST encode guest framing from sanitized headers and bounded body reads.
  # Upload/download bodies MUST NOT accumulate in full. The owner holds the local
  # socket so independent lease expiry closes it even during blocked I/O. Guest
  # trailers and unsolicited protocol upgrades MUST NOT change response authority.
  @doc false
  @spec forward(Plug.Conn.t(), tuple(), map(), binary() | nil) :: Plug.Conn.t()
  def forward(conn, {module, config}, grant, source_vm_id) do
    with {:request_headers, {:ok, headers}} <-
           {:request_headers,
            Headers.request(conn.req_headers, %{
              host: conn.host,
              port: conn.port,
              remote_ip: conn.remote_ip,
              user_id: grant.user_id,
              source_vm_id: source_vm_id
            })},
         {:request_method, true} <- {:request_method, conn.method not in ["CONNECT", "TRACE"]},
         {:connector, {:ok, socket}} <-
           {:connector, Audi.StreamConnector.open({module, config}, grant)} do
      try do
        :ok =
          :inet.setopts(socket,
            active: false,
            packet: :raw,
            buffer: 65_536,
            send_timeout: 1000,
            send_timeout_close: true
          )

        with {:initiate, {:ok, upstream}} <-
               {:initiate,
                Mint.HTTP1.initiate(:http, socket, conn.host, grant.binding.port,
                  mode: :passive,
                  max_header_list_size: 65_536,
                  log: false
                )},
             {:socket_options, :ok} <- {:socket_options, :inet.setopts(socket, buffer: 65_536)},
             path =
               conn.request_path <>
                 if(conn.query_string == "", do: "", else: "?" <> conn.query_string),
             {:request, {:ok, upstream, ref}} <-
               {:request,
                Mint.HTTP1.request(
                  upstream,
                  conn.method,
                  path,
                  headers ++ [{"connection", "close"}],
                  :stream
                )} do
          case upload(conn, upstream, ref) do
            {:ok, conn, upstream} -> download(conn, upstream, ref, nil, false)
            {:error, phase, reason} -> fail(conn, phase, reason)
          end
        else
          {:initiate, {:error, error}} -> fail(conn, :initiate, failure_reason(error))
          {:socket_options, _} -> fail(conn, :socket_options, :other)
          {:request, {:error, _, error}} -> fail(conn, :request, failure_reason(error))
        end
      after
        :gen_tcp.close(socket)
      end
    else
      {:request_headers, _} -> fail(conn, :request_headers, :protocol)
      {:request_method, _} -> fail(conn, :request_method, :other)
      {:connector, _} -> fail(conn, :connector, :other)
    end
  end

  def forward(conn, _, _, _), do: fail(conn, :connector, :other)

  defp peer_token(conn, label, app_port) do
    case get_req_header(conn, "authorization") do
      ["galileo-peer " <> token] ->
        case OverallsProtocol.Integration.peer_open_request(%{
               "version" => 1,
               "peer_token" => token,
               "label" => label,
               "app_port" => app_port
             }) do
          {:ok, _} -> {:ok, token}
          _ -> {:error, :invalid_peer_token}
        end

      values when is_list(values) ->
        if Enum.any?(values, &String.starts_with?(&1, "galileo-peer")),
          do: {:error, :invalid_peer_token},
          else: {:ok, nil}
    end
  end

  defp admit(client, label, app_port, cookie, nil) do
    case Client.open_web(client, label, app_port, cookie) do
      {:ok, grant} -> {:ok, grant, nil}
      error -> error
    end
  end

  defp admit(client, label, app_port, _cookie, token) do
    case Client.open_peer(client, label, app_port, token) do
      {:ok, %{grant: grant, attestation: %{source_vm_id: source_vm_id}}} ->
        {:ok, grant, source_vm_id}

      _ ->
        {:error, :peer_unavailable}
    end
  end

  @spec upload(Plug.Conn.t(), Mint.HTTP1.t(), reference()) ::
          {:ok, Plug.Conn.t(), Mint.HTTP1.t()} | {:error, failure_phase(), failure_reason()}
  defp upload(conn, upstream, ref) do
    case read_body(conn, length: 65_536, read_length: 65_536, read_timeout: 5000) do
      {:more, bytes, conn} ->
        case Mint.HTTP1.stream_request_body(upstream, ref, bytes) do
          {:ok, upstream} -> upload(conn, upstream, ref)
          {:error, _, error} -> {:error, :upload_body, failure_reason(error)}
        end

      {:ok, bytes, conn} ->
        with {:upload_body, {:ok, upstream}} <-
               {:upload_body, Mint.HTTP1.stream_request_body(upstream, ref, bytes)},
             {:upload_eof, {:ok, upstream}} <-
               {:upload_eof, Mint.HTTP1.stream_request_body(upstream, ref, :eof)} do
          {:ok, conn, upstream}
        else
          {:upload_body, {:error, _, error}} -> {:error, :upload_body, failure_reason(error)}
          {:upload_eof, {:error, _, error}} -> {:error, :upload_eof, failure_reason(error)}
        end

      _ ->
        {:error, :read_body, :other}
    end
  end

  defp download(conn, upstream, ref, status, sent) do
    case Mint.HTTP1.recv(upstream, 0, 5000) do
      {:ok, upstream, events} ->
        case events(events, conn, ref, status, sent) do
          {:more, conn, status, sent} -> download(conn, upstream, ref, status, sent)
          {:done, conn} -> conn
          {:error, conn, phase, reason} -> fail(conn, phase, reason, length(events))
        end

      {:error, _, error, events} ->
        fail(conn, :recv, failure_reason(error), length(events))
    end
  end

  defp events([], conn, _, status, sent), do: {:more, conn, status, sent}

  defp events([{:status, ref, status} | rest], conn, ref, _, false)
       when status in 100..599 and status != 101,
       do: events(rest, conn, ref, status, false)

  defp events([{:headers, ref, _} | rest], conn, ref, status, false) when status in 100..199,
    do: events(rest, conn, ref, nil, false)

  defp events([{:headers, ref, headers} | rest], conn, ref, status, false)
       when status in 200..599 do
    with {:ok, headers} <- Headers.response(headers) do
      conn = %{conn | resp_headers: conn.resp_headers ++ headers}
      conn = send_chunked(conn, status)
      events(rest, conn, ref, status, true)
    else
      _ -> {:error, conn, :response_headers, :protocol}
    end
  end

  defp events([{:headers, ref, _trailers} | rest], conn, ref, status, true),
    do: events(rest, conn, ref, status, true)

  defp events([{:data, ref, data} | rest], conn, ref, status, true) do
    case chunk(conn, data) do
      {:ok, conn} -> events(rest, conn, ref, status, true)
      _ -> {:error, conn, :downstream_body, :other}
    end
  end

  defp events([{:done, ref}], conn, ref, _, true), do: {:done, conn}
  defp events(_, conn, _, _, _), do: {:error, conn, :response_events, :protocol}

  # @cc [owner:ghuntley,label:security;observability] audi-http-failure-closed-diagnostics
  # Proxy failures MUST emit only the catalogued literal phase, finite error
  # category, response state and bounded event count. Raw Mint errors, HTTP
  # events, request data and payloads MUST NOT reach diagnostics. Classification
  # MUST preserve the existing 502 or interrupted-response shutdown behavior.
  @spec fail(Plug.Conn.t(), failure_phase(), failure_reason(), non_neg_integer()) :: Plug.Conn.t()
  defp fail(conn, phase, reason, response_events \\ 0) do
    Audi.Events.emit("audi.http_proxy_failed",
      phase: phase,
      reason: reason,
      response_state:
        if(conn.state in [:sent, :chunked, :upgraded], do: :after_headers, else: :before_headers),
      response_events: min(response_events, 2_147_483_647)
    )

    fail(conn)
  end

  @spec failure_reason(Mint.Types.error()) :: failure_reason()
  defp failure_reason(%Mint.TransportError{reason: :timeout}), do: :timeout

  defp failure_reason(%Mint.TransportError{reason: reason})
       when reason in [:closed, :econnreset, :enotconn, :epipe],
       do: :closed

  defp failure_reason(%Mint.HTTPError{reason: :closed}), do: :closed
  defp failure_reason(%Mint.HTTPError{}), do: :protocol
  defp failure_reason(_), do: :other

  defp fail(%{state: state}) when state in [:sent, :chunked, :upgraded] do
    # Never turn an interrupted body into a successful terminating chunk.
    exit(:shutdown)
  end

  defp fail(conn), do: send_resp(conn, 502, "Upstream unavailable\n")
end
