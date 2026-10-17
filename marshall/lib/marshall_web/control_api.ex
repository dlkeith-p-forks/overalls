defmodule MarshallWeb.ControlAPI do
  @moduledoc "The control WebSocket upgrade (ADR-0142) on the fleet listener."
  @behaviour Plug
  import Plug.Conn

  alias OverallsProtocol.Control.Envelope

  @max_token 128

  @impl true
  def init(options), do: options

  # @cc [owner:ghuntley,label:security;protocol] control-upgrade-authenticated
  # Only a GET upgrade of /api/control/v1 over HTTPS may reach the control
  # socket. A missing or different overalls-control version MUST get 426 and an
  # unknown service or failed credential 401, both before any socket process
  # exists; responses carry no credential, header or body detail.
  @impl true
  def call(%{path_info: ["api", "control", "v1"]} = conn, options) do
    Logger.metadata(marshall_authentication: true)

    with true <- conn.scheme == :https,
         "GET" <- conn.method,
         :ok <- version(conn),
         {:ok, service, module} <- service(conn),
         {:ok, token} <- bearer(conn),
         {:ok, principal} <- authenticate(module, token) do
      conn
      |> WebSockAdapter.upgrade(
        Keyword.get(options, :socket, Marshall.Control.Socket),
        Map.merge(
          Keyword.get(options, :socket_state, %{}),
          %{service: service, module: module, principal: principal}
        ),
        timeout: 60_000,
        max_frame_size: Marshall.Control.Service.limits(module).inbound,
        compress: false
      )
      |> halt()
    else
      {:status, status} -> refuse(conn, status)
      _ -> refuse(conn, 404)
    end
  end

  def call(conn, _options), do: conn

  @spec version(Plug.Conn.t()) :: :ok | {:status, 426}
  defp version(conn) do
    if get_req_header(conn, "overalls-control") == ["#{Envelope.version()}"],
      do: :ok,
      else: {:status, 426}
  end

  @spec service(Plug.Conn.t()) :: {:ok, String.t(), module()} | {:status, 401}
  defp service(conn) do
    with [name] <- get_req_header(conn, "overalls-service"),
         {:ok, module} <- Marshall.Control.Service.fetch(name) do
      {:ok, name, module}
    else
      _ -> {:status, 401}
    end
  end

  @spec bearer(Plug.Conn.t()) :: {:ok, binary()} | {:status, 401}
  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) in 1..@max_token -> {:ok, token}
      _ -> {:status, 401}
    end
  end

  # A crashed or incomplete check (e.g. an unreachable database or an
  # undecryptable stored secret) is not a refusal.
  @spec authenticate(module(), binary()) :: {:ok, term()} | {:status, 401 | 503}
  defp authenticate(module, token) do
    case module.authenticate(token) do
      {:ok, principal} -> {:ok, principal}
      :unavailable -> {:status, 503}
      _ -> {:status, 401}
    end
  rescue
    _ -> {:status, 503}
  end

  @spec refuse(Plug.Conn.t(), 401 | 404 | 426 | 503) :: Plug.Conn.t()
  defp refuse(conn, status) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, "")
    |> halt()
  end
end
