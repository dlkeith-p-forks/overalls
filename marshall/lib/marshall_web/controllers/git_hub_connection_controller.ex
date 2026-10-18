defmodule MarshallWeb.GitHubConnectionController do
  use MarshallWeb, :controller

  alias Marshall.Accounts.{Login, Security, User}

  # @cc [owner:ghuntley,label:security] github-ceremony-current-login
  # Both ceremony endpoints MUST verify the current stored browser login. The
  # OAuth attempt MUST bind that login and user; a callback MUST NOT become a
  # Marshall sign-in. Callback codes and state MUST NOT survive in redirect URLs,
  # flash messages or session storage. Every response MUST prohibit caching and
  # referrer disclosure, including malformed and unauthenticated callbacks.
  @spec start(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start(conn, _params) do
    conn = private_response(conn)

    with {:ok, user, jti} <- current_login(conn),
         {:ok, %{url: url}} <- Marshall.GitHub.begin_authorization(user, jti) do
      redirect(conn, external: url)
    else
      :no_login -> redirect(conn, to: "/sign-in")
      _ -> failed(conn)
    end
  end

  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, %{"state" => state, "code" => code})
      when is_binary(state) and is_binary(code) do
    conn = private_response(conn)

    with {:ok, user, jti} <- current_login(conn),
         {:ok, _status} <- Marshall.GitHub.callback(user, jti, state, code) do
      conn
      |> put_flash(:info, gettext("GitHub connected."))
      |> redirect(to: "/integrations")
    else
      :no_login -> redirect(conn, to: "/sign-in")
      _ -> failed(conn)
    end
  end

  def callback(conn, _params), do: conn |> private_response() |> failed()

  @spec current_login(Plug.Conn.t()) :: {:ok, User.t(), String.t()} | :no_login
  defp current_login(conn) do
    with %User{} = user <- conn.assigns[:current_user],
         {:ok, jti, _expiry} <- Login.verify(get_session(conn, "user_token"), user) do
      {:ok, Security.bind(user, jti), jti}
    else
      _ -> :no_login
    end
  end

  @spec private_response(Plug.Conn.t()) :: Plug.Conn.t()
  defp private_response(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  @spec failed(Plug.Conn.t()) :: Plug.Conn.t()
  defp failed(conn) do
    conn
    |> put_flash(:error, gettext("GitHub could not be connected. Try again from Integrations."))
    |> redirect(to: "/integrations")
  end
end
