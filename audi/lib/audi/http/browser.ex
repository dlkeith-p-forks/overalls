defmodule Audi.HTTP.Browser do
  @moduledoc "Host-only browser state and callback redemption; cookies are not stream grants."
  import Plug.Conn
  alias Audi.Control.Client
  require Audi.Events
  @state "__Host-audi_state"
  @return "__Host-audi_return"
  @session "__Host-audi_session"
  @cookie [http_only: true, secure: true, same_site: "Lax", path: "/"]

  # @cc [owner:ghuntley,label:security] audi-browser-state-cookie
  # Sign-in MUST bind a fresh canonical random state to the exact TLS hostname.
  # State and session cookies MUST be host-only, Secure, HttpOnly and SameSite.
  # Callback redemption MUST require exactly one state cookie and the closed
  # code/ticket query. Raw secrets MUST NOT reach guest requests or referrers.
  @spec start(Plug.Conn.t(), Client.t(), binary(), binary()) :: Plug.Conn.t()
  def start(conn, client, zone, browser_origin) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with {:ok, label, port} <- target(conn.host, zone),
         {:ok, result} <- Client.begin_web_login(client, label, port, state, conn.host) do
      Audi.Events.emit("audi.web_login_started", [])

      path =
        conn.request_path <> if(conn.query_string == "", do: "", else: "?" <> conn.query_string)

      path = if return_path?(path), do: path, else: "/"

      conn
      |> private()
      |> put_resp_cookie(@state, state, @cookie ++ [max_age: 300])
      |> put_resp_cookie(
        @return,
        Base.url_encode64(path, padding: false),
        @cookie ++ [max_age: 300]
      )
      |> put_resp_header("location", browser_origin <> "/audi/authorize/" <> result.ticket)
      |> send_resp(303, "")
    else
      _ ->
        Audi.Events.emit("audi.web_login_denied", reason: :login_begin_failed)
        unavailable(conn)
    end
  end

  @spec callback(Plug.Conn.t(), Client.t()) :: Plug.Conn.t()
  def callback(conn, client) do
    result =
      with true <- conn.method == "GET" and byte_size(conn.query_string) <= 1024,
           true <- length(String.split(conn.query_string, "&")) == 2,
           %{"ticket" => ticket, "code" => code} = params when map_size(params) == 2 <-
             URI.decode_query(conn.query_string),
           {:ok, state} <- cookie(conn, @state),
           {:ok, result} <- Client.exchange_web_login(client, ticket, code, state, conn.host),
           age = min(DateTime.diff(result.expires_at, DateTime.utc_now()), 43_200),
           true <- age > 0 do
        {:ok, result.cookie, age}
      else
        failure ->
          Audi.Events.emit("audi.web_login_denied", reason: login_denial(failure))
          :error
      end

    destination =
      with {:ok, encoded} <- cookie(conn, @return),
           {:ok, path} <- Base.url_decode64(encoded, padding: false),
           true <- return_path?(path),
           do: path,
           else: (_ -> "/")

    conn =
      conn
      |> private()
      |> delete_resp_cookie(@state, @cookie)
      |> delete_resp_cookie(@return, @cookie)

    case result do
      {:ok, token, age} ->
        Audi.Events.emit("audi.web_login_redeemed", [])

        conn
        |> put_resp_cookie(@session, token, @cookie ++ [max_age: age])
        |> put_resp_header("location", destination)
        |> send_resp(303, "")

      :error ->
        unavailable(conn)
    end
  rescue
    _ -> unavailable(conn)
  end

  @spec credential(Plug.Conn.t()) :: {:ok, binary()} | :error
  def credential(conn) do
    with {:ok, token} <- cookie(conn, @session),
         true <- OverallsProtocol.WebLogin.token?(token, :cookie),
         do: {:ok, token},
         else: (_ -> :error)
  end

  @doc false
  @spec return_path?(term()) :: boolean()
  def return_path?(path) when is_binary(path) and byte_size(path) in 1..2048,
    do:
      String.valid?(path) and String.starts_with?(path, "/") and
        not String.starts_with?(path, ["//", "/_audi/"]) and
        not Regex.match?(~r/[\\\x00-\x20\x7f]/, path)

  def return_path?(_), do: false

  defp login_denial({:error, reason}) when is_atom(reason), do: reason
  defp login_denial(:error), do: :missing_state
  defp login_denial(_), do: :invalid_callback

  defp cookie(conn, name) do
    values =
      for {"cookie", value} <- conn.req_headers,
          item <- String.split(value, ";"),
          [^name, token] <- [String.split(String.trim(item), "=", parts: 2)],
          do: token

    case values do
      [value] when byte_size(value) <= 4096 -> {:ok, value}
      _ -> :error
    end
  end

  @spec target(binary(), binary()) :: {:ok, binary(), integer()} | :error
  def target(host, zone) when is_binary(host) and is_binary(zone) do
    if String.ends_with?(host, "." <> zone) do
      host
      |> String.replace_suffix("." <> zone, "")
      |> OverallsProtocol.IngressName.application_label()
    else
      :error
    end
  end

  def target(_, _), do: :error

  defp private(conn),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")

  defp unavailable(conn), do: conn |> private() |> send_resp(403, "Sign-in unavailable\n")
end
