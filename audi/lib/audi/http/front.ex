defmodule Audi.HTTP.Front do
  @moduledoc "Ingress origin checks, HTTPS redirection and authenticated web forwarding."
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(options), do: options

  # @cc [owner:ghuntley,label:security] audi-http-origin-binding
  # Redirects MUST use an installed canonical hostname or a valid single-layer
  # Inception hostname inside the configured zone, never forwarded headers.
  # A nested redirect MUST NOT require outer custody of an inner certificate,
  # grant access or contact the guest. HTTPS still requires its installed SNI.
  # HTTPS Host MUST equal this connection's SNI. A certificate does not grant
  # access: without current route/session authority, application requests MUST
  # return 503 without contacting a guest. Client IP overrides MUST come only
  # from the listener's verified parent metadata, never request headers. The reserved callback may redeem
  # browser state through Marshall, but MUST NOT forward secrets or guest bytes.
  @impl true
  def call(conn, options) do
    Overalls.Diagnostics.Tracing.with_span("audi.http", [], fn -> call_traced(conn, options) end)
  end

  @spec call_traced(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  defp call_traced(conn, options) do
    :logger.update_process_metadata(%{audi_private: true})

    conn =
      case options[:verified_client_peer] do
        {{_, _, _, _} = address, _port} -> %{conn | remote_ip: address}
        _ -> conn
      end

    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("connection", "close")

    with [_] <- get_req_header(conn, "host"),
         true <- accepted_host?(conn, options),
         true <- String.starts_with?(conn.request_path, "/") do
      case conn.scheme do
        :http ->
          port = if options[:https_port] == 443, do: "", else: ":#{options[:https_port]}"
          query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
          location = "https://" <> conn.host <> port <> conn.request_path <> query
          conn |> put_resp_header("location", location) |> send_resp(308, "")

        :https ->
          sni = conn |> get_ssl_data() |> Keyword.get(:sni_hostname)

          cond do
            not (is_list(sni) and List.to_string(sni) == conn.host) or
                conn.port != Keyword.get(options, :https_port, 443) ->
              send_resp(conn, 421, "Misdirected request\n")

            Audi.HTTP.EditorAssets.host?(conn.host, options[:zone]) ->
              Audi.HTTP.EditorAssets.call(conn, options)

            String.starts_with?(conn.host, "e-") and conn.request_path == "/_editor/callback" and
                not is_nil(options[:client]) ->
              case Audi.HTTP.EditorBrowser.target(conn.host, options[:zone]) do
                {:ok, _} -> Audi.HTTP.EditorBrowser.callback(conn, options[:client])
                _ -> send_resp(conn, 421, "Misdirected request\n")
              end

            String.starts_with?(conn.request_path, "/_editor/") ->
              send_resp(conn, 404, "Unavailable\n")

            String.starts_with?(conn.host, "e-") and not is_nil(options[:client]) and
                not is_nil(options[:connector]) ->
              Audi.HTTP.Editor.call(conn, options)

            conn.request_path == "/_audi/callback" and not is_nil(options[:client]) ->
              Audi.HTTP.Browser.callback(conn, options[:client])

            String.starts_with?(conn.request_path, "/_audi/") ->
              send_resp(conn, 404, "Unavailable\n")

            not is_nil(options[:client]) and not is_nil(options[:connector]) and
                not is_nil(options[:zone]) ->
              Audi.HTTP.Proxy.call(conn, options)

            true ->
              send_resp(conn, 503, "Service unavailable\n")
          end
      end
    else
      _ -> send_resp(conn, 421, "Misdirected request\n")
    end
  end

  defp accepted_host?(conn, options) do
    is_list(Audi.TLS.Store.sni(options[:store], conn.host)) or
      (conn.scheme == :http and
         match?({:ok, _, _}, OverallsProtocol.InceptionName.route(conn.host, options[:zone])))
  end
end
