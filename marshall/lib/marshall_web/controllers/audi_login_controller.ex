defmodule MarshallWeb.AudiLoginController do
  use MarshallWeb, :controller

  # @cc [owner:ghuntley,label:security] audi-browser-approval-origin
  # Only a canonical exchange ticket may enter the fixed local sign-in return
  # path. Approval MUST use the current stored login and domain web permission.
  # Callback hosts MUST come from the domain's configured zone, never request
  # headers or a supplied return URL. Secret-bearing redirects MUST forbid cache
  # storage and referrers; gateway credentials cannot approve browser identity.
  @spec authorize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authorize(conn, %{"ticket" => ticket}) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")

    if OverallsProtocol.WebLogin.token?(ticket, :ticket) do
      case conn.assigns[:current_user] do
        %Marshall.Accounts.User{} = user ->
          case Marshall.Ingress.authorize_web_login(
                 %{ticket: ticket, login_token: get_session(conn, "user_token")},
                 actor: user
               ) do
            {:ok, result} ->
              query = URI.encode_query(%{ticket: result.ticket, code: result.code})

              port = Application.get_env(:marshall, :ingress_https_port, 443)
              suffix = if port == 443, do: "", else: ":#{port}"

              redirect(conn,
                external: "https://" <> result.hostname <> suffix <> "/_audi/callback?" <> query
              )

            _ ->
              send_resp(conn, 403, dgettext("auth", "Sign-in unavailable") <> "\n")
          end

        _ ->
          conn
          |> put_session(:return_to, "/audi/authorize/" <> ticket)
          |> redirect(to: "/sign-in")
      end
    else
      send_resp(conn, 404, dgettext("auth", "Unavailable") <> "\n")
    end
  end
end
