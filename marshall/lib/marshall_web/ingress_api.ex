defmodule MarshallWeb.IngressAPI do
  @moduledoc """
  Bounded Audi HTTPS transport, separate from browser and provisioner authority.

  Only identity, DNS snapshots, host keys and host certificates remain here,
  for Inception publication and lyra's certificate renewal; gateway sessions,
  catalogs and fleet certificates run on the control WebSocket (ADR-0142).
  """
  @behaviour Plug
  import Plug.Conn
  require Marshall.Events

  @doc "Closed reason classes recorded by the uniform 503 control diagnostic."
  @spec unavailable_reasons() :: [atom()]
  defdelegate unavailable_reasons, to: Marshall.Ingress.ControlRequests

  @impl true
  def init(options), do: options

  # @cc [owner:ghuntley,label:security] ingress-api-private-control-transport
  # Audi control requests MUST use actual HTTPS, one purpose-bound bearer credential
  # and a closed bounded versioned body. Public known-hosts discovery MUST instead
  # use IngressKnownHosts' current-route-only boundary. Forwarded headers and cookies MUST
  # NOT establish service authority. Responses MUST NOT expose service credentials
  # or hashes. A new session ticket may be returned only to its admitted gateway.
  @impl true
  def call(
        %{path_info: ["api", "audi", "v1", "inception-known-hosts", label, service, layer]} = conn,
        _
      ) do
    MarshallWeb.IngressKnownHosts.nested(conn, label, service, layer)
  end

  def call(%{path_info: ["api", "audi", "v1", "known-hosts", label]} = conn, _) do
    MarshallWeb.IngressKnownHosts.call(conn, label)
  end

  def call(%{path_info: ["api", "audi" | _]} = conn, _) do
    Logger.metadata(marshall_authentication: true)
    conn = Plug.RequestId.call(conn, Plug.RequestId.init([]))
    {result, conn} = request(conn)
    respond(conn, result)
  end

  def call(conn, _), do: conn

  defp request(%{path_info: ["api", "audi", version | _]} = conn) when version != "v1",
    do: {{:error, :unsupported_version}, conn}

  defp request(conn) do
    with :ok <- transport(conn),
         ["api", "audi", "v1", route]
         when route in [
                "identity",
                "host-key",
                "host-certificate",
                "dns-snapshot"
              ] <-
           conn.path_info,
         "POST" <- conn.method,
         ["Bearer " <> token] when byte_size(token) <= 80 <- get_req_header(conn, "authorization"),
         [content_type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _} <- Plug.Conn.Utils.content_type(content_type),
         maximum = 4096,
         {:ok, body, conn} <-
           read_body(conn, length: maximum, read_length: maximum, read_timeout: 5000) do
      result =
        if byte_size(body) <= maximum,
          do: dispatch(route, token, body),
          else: {:error, :message_too_large}

      {result, conn}
    else
      {:error, :https_required} -> {{:error, :https_required}, conn}
      {:more, _, conn} -> {{:error, :message_too_large}, conn}
      _ -> {{:error, :invalid_request}, conn}
    end
  rescue
    _ -> {{:error, :unavailable}, conn}
  end

  defp dispatch(route, token, body) do
    case Jason.decode(body) do
      {:ok, %{"version" => 1} = value} when route == "host-certificate" ->
        message(route, token, value)

      {:ok, %{"version" => 1} = value} ->
        Marshall.Ingress.ControlRequests.handle(route, token, value)

      {:ok, %{"version" => version}} when version != 1 ->
        {:error, :unsupported_version}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp message("host-certificate", token, %{"version" => 1, "public_key" => key} = value)
       when map_size(value) == 2 do
    Marshall.SSH.host_certificate(%{role: :audi, token: token, public_key: key},
      actor: Marshall.Authorization.SystemActor.compute()
    )
  end

  defp message(_, _, _), do: {:error, :invalid_request}

  defp transport(%{scheme: :https}), do: :ok

  defp transport(%{remote_ip: ip}) do
    if ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] and
         Application.get_env(:marshall, :ingress_allow_insecure_loopback, false),
       do: :ok,
       else: {:error, :https_required}
  end

  defp respond(conn, {:ok, result}), do: json(conn, 200, result)

  defp respond(conn, {:error, %Marshall.Ingress.Error{reason: reason}}),
    do: respond(conn, {:error, reason})

  defp respond(conn, {:error, %Ash.Error.Invalid{errors: [error]}}),
    do: respond(conn, {:error, error})

  defp respond(conn, {:error, :authentication_required}) do
    Marshall.Events.emit("api.request_unauthorized", reason: :authentication_required)
    json(conn, 401, %{error: "authentication_required"})
  end

  defp respond(conn, {:error, :capacity}), do: json(conn, 429, %{error: "capacity"})

  defp respond(conn, {:error, :unauthorized}) do
    Marshall.Events.emit("api.request_unauthorized", reason: :unauthorized)
    json(conn, 401, %{error: "unauthorized"})
  end

  defp respond(conn, {:error, reason}) when reason in [:forbidden, :vm_deleted],
    do: json(conn, 403, %{error: "unauthorized"})

  defp respond(conn, {:error, :session_limit}), do: json(conn, 429, %{error: "session_limit"})

  defp respond(conn, {:error, :host_key_conflict}),
    do: json(conn, 409, %{error: "host_key_conflict"})

  defp respond(conn, {:error, :invalid_request}), do: json(conn, 400, %{error: "invalid_request"})
  defp respond(conn, {:error, :https_required}), do: json(conn, 403, %{error: "https_required"})

  defp respond(conn, {:error, :unsupported_version}),
    do: json(conn, 426, %{error: "unsupported_version"})

  defp respond(conn, {:error, :message_too_large}),
    do: json(conn, 413, %{error: "message_too_large"})

  # The uniform 503 stays unchanged for callers; ControlRequests records the
  # closed reason class (ingress-unavailable-reason-class).
  defp respond(conn, result) do
    Marshall.Ingress.ControlRequests.unavailable(result)
    json(conn, 503, %{error: "temporarily_unavailable"})
  end

  defp json(conn, status, value) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(value))
    |> halt()
  end
end
