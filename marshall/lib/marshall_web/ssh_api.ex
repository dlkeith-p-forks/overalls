defmodule MarshallWeb.SSHAPI do
  @moduledoc """
  Bounded gateway HTTPS interface for readiness and host certificates,
  isolated from browser authentication. Session and command requests run on
  the control WebSocket (ADR-0142).
  """
  @behaviour Plug
  import Plug.Conn
  @maximum 16_384

  @impl true
  def init(options), do: options

  # @cc [owner:ghuntley,label:security] ssh-api-bounded-private-transport
  # Gateway requests MUST require actual HTTPS (or explicit loopback development),
  # one bearer header, a closed versioned JSON body and bounded reads. Browser
  # cookies and forwarded headers MUST NOT substitute for gateway authority.
  @impl true
  def call(%{path_info: ["api", "ssh" | _]} = conn, _) do
    Logger.metadata(marshall_authentication: true)
    conn = Plug.RequestId.call(conn, Plug.RequestId.init([]))
    started = System.monotonic_time()
    {result, conn} = request(conn)
    conn = respond(conn, result)

    Overalls.Diagnostics.Metrics.record(
      [:marshall, :ssh, :request],
      %{duration: System.monotonic_time() - started},
      %{status: conn.status}
    )

    conn
  end

  def call(conn, _), do: conn

  defp request(%{path_info: ["api", "ssh", version | _]} = conn) when version != "v1",
    do: {{:error, :unsupported_version}, conn}

  defp request(conn) do
    with :ok <- transport(conn),
         ["api", "ssh", "v1", route]
         when route in ["ready", "host-certificate"] <-
           conn.path_info,
         "POST" <- conn.method,
         ["Bearer " <> token] when byte_size(token) <= 80 <- get_req_header(conn, "authorization"),
         [content_type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _} <- Plug.Conn.Utils.content_type(content_type),
         {:ok, body, conn} <-
           read_body(conn, length: @maximum, read_length: @maximum, read_timeout: 5000) do
      if byte_size(body) <= @maximum,
        do: {dispatch(route, token, body), conn},
        else: {{:error, :message_too_large}, conn}
    else
      {:error, :https_required} -> {{:error, :https_required}, conn}
      {:more, _, conn} -> {{:error, :message_too_large}, conn}
      _ -> {{:error, :invalid_request}, conn}
    end
  end

  defp dispatch("host-certificate", token, body) do
    with {:ok, %{"version" => 1, "public_key" => key} = value} <- Jason.decode(body),
         true <- map_size(value) == 2 do
      Marshall.SSH.host_certificate(%{role: :porsche, token: token, public_key: key},
        actor: Marshall.Authorization.SystemActor.compute()
      )
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp dispatch(route, token, body) do
    case Jason.decode(body) do
      {:ok, decoded} -> Marshall.SSH.ControlRequests.handle(route, token, decoded)
      _ -> {:error, :invalid_request}
    end
  end

  defp transport(%{scheme: :https}), do: :ok

  defp transport(%{remote_ip: ip}) do
    if ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] and
         Application.get_env(:marshall, :ssh_allow_insecure_loopback, false),
       do: :ok,
       else: {:error, :https_required}
  end

  defp respond(conn, result) do
    case Marshall.SSH.ControlRequests.classify(result) do
      {:ok, value} -> json(conn, 200, value)
      {:error, status, name} -> json(conn, status, %{error: name})
    end
  end

  defp json(conn, status, result) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(result))
    |> halt()
  end
end
