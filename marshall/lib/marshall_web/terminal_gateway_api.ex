defmodule MarshallWeb.TerminalGatewayAPI do
  @moduledoc """
  Porsche's terminal attach stream on the fleet listener (ADR-0223).

  `GET /api/terminal-gateway/v1/stream` upgrades into `Marshall.Terminal.Viewer`
  with an `{:ssh, gateway, session}` authority. The Porsche gateway bearer and
  the attaching connection's SSH session are checked before any socket process
  exists; the single-use ticket is consumed by the viewer before bytes flow.
  """
  @behaviour Plug
  import Plug.Conn

  alias OverallsProtocol.TerminalAttach

  @impl true
  def init(options), do: options

  # @cc [owner:ghuntley,label:security] terminal-gateway-stream-authenticated
  # Upgrade MUST require HTTPS, exactly one gateway bearer, one SSH session
  # credential and one bounded ticket header, plus bounded cursor and paired
  # geometry. A refused or unknown gateway or SSH session MUST get 401, a
  # malformed request 400 and an unanswered check 503, all before any socket
  # exists. Browser cookies and login tokens MUST NOT authorize this route, and
  # responses carry no credential, header or body detail.
  @impl true
  def call(%Plug.Conn{path_info: ["api", "terminal-gateway", "v1", "stream"]} = conn, options) do
    Logger.metadata(marshall_authentication: true)

    with true <- conn.scheme == :https,
         "GET" <- conn.method,
         {:ok, request} <- request(conn),
         :ok <- authenticate(request) do
      conn
      |> WebSockAdapter.upgrade(
        Keyword.get(options, :socket, Marshall.Terminal.Viewer),
        %{
          ticket: request.ticket,
          authority: {:ssh, request.gateway, request.session},
          cursor: request.cursor,
          cols: request.cols,
          rows: request.rows
        },
        timeout: :infinity,
        max_frame_size: 65_550,
        compress: false
      )
      |> halt()
    else
      {:status, status} -> refuse(conn, status)
      _ -> refuse(conn, 404)
    end
  end

  def call(conn, _options), do: conn

  @type request :: %{
          gateway: binary(),
          session: binary(),
          ticket: binary(),
          cursor: non_neg_integer(),
          cols: non_neg_integer(),
          rows: non_neg_integer()
        }

  @spec request(Plug.Conn.t()) :: {:ok, request()} | {:status, 400 | 401}
  defp request(conn) do
    conn = fetch_query_params(conn)

    with {:ok, gateway} <- bearer(conn),
         [session] when byte_size(session) <= 80 <-
           get_req_header(conn, TerminalAttach.session_header()),
         [ticket] when byte_size(ticket) in 20..64 <-
           get_req_header(conn, TerminalAttach.ticket_header()),
         true <- Map.keys(conn.query_params) -- ["cursor", "cols", "rows"] == [],
         {:ok, cursor} <-
           bounded_integer(conn.query_params["cursor"], 0, 9_223_372_036_854_775_807),
         {:ok, cols} <- bounded_integer(conn.query_params["cols"], 0, 4096),
         {:ok, rows} <- bounded_integer(conn.query_params["rows"], 0, 512),
         true <- cols == 0 == (rows == 0) do
      {:ok,
       %{
         gateway: gateway,
         session: session,
         ticket: ticket,
         cursor: cursor,
         cols: cols,
         rows: rows
       }}
    else
      {:status, status} -> {:status, status}
      [] -> {:status, 401}
      _ -> {:status, 400}
    end
  end

  @spec bearer(Plug.Conn.t()) :: {:ok, binary()} | {:status, 401}
  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) in 1..80 -> {:ok, token}
      _ -> {:status, 401}
    end
  end

  @spec authenticate(request()) :: :ok | {:status, 401 | 503}
  defp authenticate(request) do
    case Marshall.SSH.Authority.session_live?(request.gateway, request.session) do
      true -> :ok
      false -> {:status, 401}
      :unavailable -> {:status, 503}
    end
  end

  @spec bounded_integer(term(), non_neg_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | :error
  defp bounded_integer(nil, default, _maximum), do: {:ok, default}

  defp bounded_integer(value, _default, maximum)
       when is_binary(value) and byte_size(value) <= 20 do
    case Integer.parse(value) do
      {number, ""} when number >= 0 and number <= maximum -> {:ok, number}
      _ -> :error
    end
  end

  defp bounded_integer(_value, _default, _maximum), do: :error

  @spec refuse(Plug.Conn.t(), 400 | 401 | 404 | 503) :: Plug.Conn.t()
  defp refuse(conn, status) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, "")
    |> halt()
  end
end
