defmodule MarshallWeb.EditorController do
  use MarshallWeb, :controller

  # @cc [owner:ghuntley,label:security] editor-browser-origin-redirect
  # Launch and approval MUST use fresh domain authority and configured origins.
  # User supplied hosts/return URLs MUST NOT influence redirects. Secret-bearing
  # responses MUST forbid caching and referrers; malformed tickets MUST NOT set
  # a sign-in return path. Approval MUST retain the original stored login.
  @spec launch(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def launch(conn, %{"id" => id}) do
    conn = private_response(conn)

    case conn.assigns[:current_user] do
      %Marshall.Accounts.User{} = user ->
        case Marshall.Editor.launch(%{vm_id: id}, actor: bound_user(conn, user)) do
          {:ok, result} -> redirect(conn, external: result.origin <> "/")
          _ -> send_resp(conn, 403, "VS Code is unavailable for this machine.\n")
        end

      _ ->
        if OverallsProtocol.uuid?(id) do
          conn
          |> put_session(:return_to, "/machines/" <> id <> "/code")
          |> redirect(to: "/sign-in")
        else
          send_resp(conn, 404, "Unavailable\n")
        end
    end
  end

  @spec authorize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authorize(conn, %{"ticket" => ticket}) do
    conn = private_response(conn)

    if OverallsProtocol.EditorLogin.token?(ticket, :ticket) do
      case conn.assigns[:current_user] do
        %Marshall.Accounts.User{} = user ->
          case Marshall.Editor.authorize_editor_login(
                 %{ticket: ticket, login_token: get_session(conn, "user_token")},
                 actor: user
               ) do
            {:ok, result} ->
              query = URI.encode_query(%{ticket: result.ticket, code: result.code})
              port = Application.get_env(:marshall, :ingress_https_port, 443)
              suffix = if port == 443, do: "", else: ":#{port}"

              redirect(conn,
                external: "https://" <> result.hostname <> suffix <> "/_editor/callback?" <> query
              )

            _ ->
              send_resp(conn, 403, "Sign-in unavailable\n")
          end

        _ ->
          conn
          |> put_session(:return_to, "/editor/authorize/" <> ticket)
          |> redirect(to: "/sign-in")
      end
    else
      send_resp(conn, 404, "Unavailable\n")
    end
  end

  @spec bound_user(Plug.Conn.t(), Marshall.Accounts.User.t()) :: Marshall.Accounts.User.t()
  defp bound_user(conn, user) do
    case Marshall.Accounts.Login.verify(get_session(conn, "user_token"), user) do
      {:ok, jti, _} -> Marshall.Accounts.Security.bind(user, jti)
      _ -> user
    end
  end

  @spec private_response(Plug.Conn.t()) :: Plug.Conn.t()
  defp private_response(conn),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
end
