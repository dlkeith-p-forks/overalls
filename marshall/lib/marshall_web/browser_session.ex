defmodule MarshallWeb.BrowserSession do
  @moduledoc """
  The browser session cookie options shared by `Plug.Session`, the LiveView
  socket `connect_info` and every test or probe that forges a session.

  `config :marshall, browser_session: :secure` (production) selects the
  `__Host-` prefixed, Secure, encrypted cookie; the default `:plain` mode keeps
  the historical `_marshall_key` name for development and tests over `http`.
  The mode is read at compile time because `Plug.Session` and the socket are
  compiled into the endpoint.

  As a plug (installed after `Plug.Session`), it also expires cookies that an
  earlier release set under a legacy name so they do not linger in browsers.
  """
  @behaviour Plug
  import Plug.Conn

  @type mode :: :secure | :plain

  @mode Application.compile_env(:marshall, :browser_session, :plain)

  @secure_key "__Host-marshall"
  @plain_key "_marshall_key"
  @legacy_remember_me "remember_me"

  # @cc [owner:ghuntley,label:security] production-host-prefixed-session-cookie
  # The :secure session cookie MUST be named with the __Host- prefix, be Secure,
  # HttpOnly, Path=/ and carry no Domain attribute, so sibling
  # *.apps.ghuntley.dev origins cannot plant or override it; it MUST be
  # encrypted as well as signed. SameSite MUST stay Lax: a magic-link landing
  # from a mail client is a cross-site top-level navigation that Strict would
  # leave signed out.
  @doc "Session options for the given mode."
  @spec options(mode()) :: keyword()
  def options(:secure) do
    [
      store: :cookie,
      key: @secure_key,
      signing_salt: "OrkORZio",
      encryption_salt: "k1yQfbd6vY7wTz2E",
      same_site: "Lax",
      secure: true,
      http_only: true,
      path: "/"
    ]
  end

  def options(:plain) do
    [
      store: :cookie,
      key: @plain_key,
      signing_salt: "OrkORZio",
      encryption_salt: "k1yQfbd6vY7wTz2E",
      same_site: "Lax",
      http_only: true,
      path: "/"
    ]
  end

  @doc "Session options for the compiled mode."
  @spec options() :: keyword()
  def options, do: options(@mode)

  @doc "The compiled session cookie name."
  @spec key() :: String.t()
  def key, do: Keyword.fetch!(options(), :key)

  @doc "The compiled mode."
  @spec mode() :: mode()
  def mode, do: @mode

  @doc "Cookie names an earlier release used that this release no longer reads."
  @spec legacy_cookie_names() :: [String.t()]
  def legacy_cookie_names do
    remember =
      to_string(
        AshAuthentication.Info.strategy!(Marshall.Accounts.User, :remember_me).cookie_name
      )

    [@plain_key, @legacy_remember_me]
    |> Enum.reject(&(&1 in [key(), remember]))
  end

  @impl true
  @spec init(Plug.opts()) :: Plug.opts()
  def init(options), do: options

  # @cc [owner:ghuntley,label:security] legacy-cookie-expiry
  # When a request still carries a legacy session or remember-me cookie name,
  # the response MUST expire that cookie. The current cookie names MUST never
  # be expired by this plug, and no cookie value is read or logged.
  @impl true
  @spec call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t()
  def call(conn, _options) do
    conn = fetch_cookies(conn)

    Enum.reduce(legacy_cookie_names(), conn, fn name, acc ->
      if Map.has_key?(acc.req_cookies, name),
        do: delete_resp_cookie(acc, name, http_only: true, same_site: "Lax"),
        else: acc
    end)
  end
end
