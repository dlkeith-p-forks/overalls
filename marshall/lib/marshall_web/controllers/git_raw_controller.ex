defmodule MarshallWeb.GitRawController do
  use MarshallWeb, :controller
  alias Marshall.Enrico.Catalog

  # @cc [owner:ghuntley,label:security] enrico-raw-authentication
  # Raw bytes MUST require a live persisted browser login and registered mirror.
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"owner" => owner, "repo" => name} = params) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    with %Marshall.Accounts.User{} = user <- conn.assigns[:current_user],
         {:ok, _, _} <- Marshall.Accounts.Login.verify(get_session(conn, "user_token"), user),
         %Marshall.Enrico.Repository{} = repo <- Catalog.get(user, owner, name),
         path when is_binary(path) and path != "" <- params["path"],
         {:ok, bytes} <-
           Catalog.inspect(user, repo, "blob", %{ref: Map.get(params, "ref", "HEAD"), path: path}) do
      filename = path |> Path.basename() |> String.replace(~r/[^A-Za-z0-9._-]/, "_")

      conn
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
      |> send_resp(200, bytes)
    else
      _ -> send_resp(conn, 404, gettext("Unavailable"))
    end
  end
end
