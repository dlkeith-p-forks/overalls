defmodule MarshallWeb.PageController do
  use MarshallWeb, :controller

  # @cc [owner:ghuntley,label:security] home-public-capture-only
  # The root path MUST direct every browser to the harmless fragment capture
  # entry before sign-in. Anonymous capture MUST render no console content and
  # MUST NOT establish identity or admit a machine.
  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    redirect(conn, to: ~p"/launch/entry")
  end

  @spec entry(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def entry(conn, _params) do
    idle_to =
      cond do
        MarshallWeb.PendingLaunch.read(get_session(conn)) -> ~p"/launch"
        conn.assigns[:current_user] -> ~p"/overview"
        true -> ~p"/sign-in"
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> render(:launch, page_title: gettext("Launch"), idle_to: idle_to)
  end
end
