defmodule MarshallWeb.DocsController do
  use MarshallWeb, :controller
  alias Marshall.Documentation

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params), do: serve(conn, "index", false)

  @spec markdown(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def markdown(conn, _params), do: serve(conn, "index", true)

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"page" => page}) do
    markdown? = String.ends_with?(page, ".md")
    slug = if markdown?, do: binary_part(page, 0, byte_size(page) - 3), else: page
    serve(conn, slug, markdown?)
  end

  @spec llms(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def llms(conn, _params), do: plain(conn, "text/plain", Documentation.llms())

  defp serve(conn, slug, markdown?) do
    case Documentation.page(slug) do
      {:ok, page} when markdown? ->
        plain(conn, "text/markdown", page.markdown)

      {:ok, page} ->
        conn
        |> put_root_layout(false)
        |> put_format("html")
        |> render(:show, page: page, pages: Documentation.pages(), layout: false)

      :error ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, gettext("Documentation not found") <> "\n")
    end
  end

  defp plain(conn, content_type, body),
    do: conn |> put_resp_content_type(content_type) |> send_resp(200, body)
end
