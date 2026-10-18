defmodule MarshallWeb.LocalePlug do
  @moduledoc "Resolves the locale without trusting arbitrary browser language tags."
  @behaviour Plug
  import Plug.Conn
  alias Marshall.Localization, as: Locale

  @spec init(keyword()) :: keyword()
  def init(options), do: options

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, options) do
    session? = Keyword.get(options, :session, false)
    user = conn.assigns[:current_user]
    override = if is_map(user), do: Map.get(user, :locale)
    saved = if session?, do: get_session(conn, "locale")
    browser = conn |> get_req_header("accept-language") |> Enum.join(",")
    inferred = Locale.negotiate(browser) || Locale.normalize(saved) || Locale.default()
    locale = Locale.choose(override, inferred, nil)
    Locale.put_locale(locale)

    conn =
      conn
      |> assign(:locale, locale)
      |> assign(:direction, Locale.direction(locale))
      |> put_resp_header("content-language", locale)
      |> merge_vary(session?)

    if session?,
      do: put_session(conn, "locale", inferred),
      else: conn
  end

  @spec merge_vary(Plug.Conn.t(), boolean()) :: Plug.Conn.t()
  defp merge_vary(conn, session?) do
    vary = conn |> get_resp_header("vary") |> Enum.join(", ")

    fields = if session?, do: "Accept-Language, Cookie", else: "Accept-Language"
    put_resp_header(conn, "vary", if(vary == "", do: fields, else: vary <> ", " <> fields))
  end
end
