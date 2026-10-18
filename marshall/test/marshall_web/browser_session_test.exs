defmodule MarshallWeb.BrowserSessionTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias MarshallWeb.BrowserSession

  @secret String.duplicate("s", 64)

  @spec session_response(keyword(), Plug.Conn.t()) :: Plug.Conn.t()
  defp session_response(options, conn) do
    %{conn | secret_key_base: @secret}
    |> Plug.Session.call(Plug.Session.init(options))
    |> fetch_session()
    |> put_session(:user_token, "fixture-login")
    |> send_resp(200, "")
  end

  @spec set_cookie(Plug.Conn.t(), String.t()) :: String.t()
  defp set_cookie(conn, name) do
    conn
    |> get_resp_header("set-cookie")
    |> Enum.find(&String.starts_with?(&1, name <> "="))
  end

  # @cc [owner:ghuntley,label:security;verification] secure-session-cookie-attributes
  # The :secure options MUST produce a __Host-marshall cookie that is Secure,
  # HttpOnly, Path=/, SameSite=Lax and domain-less, and whose value is encrypted:
  # the signing-only reader MUST NOT recover the session.
  test "secure mode issues an encrypted __Host- cookie with the required attributes" do
    response =
      session_response(BrowserSession.options(:secure), conn(:get, "https://ghuntley.dev/"))

    header = set_cookie(response, "__Host-marshall")
    assert is_binary(header)
    assert header =~ "; path=/"
    assert header =~ "; secure"
    assert header =~ "; HttpOnly"
    assert header =~ "; SameSite=Lax"
    refute header =~ ~r/domain=/i
    refute header =~ "max-age"
    assert Enum.count(get_resp_header(response, "set-cookie")) == 1

    value = response.resp_cookies["__Host-marshall"].value

    reader = fn options ->
      conn(:get, "https://ghuntley.dev/")
      |> put_req_cookie("__Host-marshall", value)
      |> Map.put(:secret_key_base, @secret)
      |> Plug.Session.call(Plug.Session.init(options))
      |> fetch_session()
      |> get_session(:user_token)
    end

    assert reader.(BrowserSession.options(:secure)) == "fixture-login"
    assert reader.(Keyword.delete(BrowserSession.options(:secure), :encryption_salt)) == nil
    refute value =~ Base.url_encode64(:erlang.term_to_binary("fixture-login"), padding: false)
  end

  test "plain mode keeps the historical name without the Secure flag for http development" do
    response = session_response(BrowserSession.options(:plain), conn(:get, "http://localhost/"))
    header = set_cookie(response, "_marshall_key")
    assert is_binary(header)
    assert header =~ "; path=/"
    assert header =~ "; HttpOnly"
    assert header =~ "; SameSite=Lax"
    refute header =~ "; secure"
    refute header =~ ~r/domain=/i

    assert Keyword.fetch!(BrowserSession.options(:plain), :encryption_salt) ==
             Keyword.fetch!(BrowserSession.options(:secure), :encryption_salt)
  end

  test "the test build is plain and the endpoint shares its options" do
    assert BrowserSession.mode() == :plain
    assert BrowserSession.key() == "_marshall_key"
    assert BrowserSession.options() == BrowserSession.options(:plain)
  end

  test "legacy cookie names exclude the current session and remember-me cookies" do
    assert BrowserSession.legacy_cookie_names() == ["remember_me"]

    assert to_string(
             AshAuthentication.Info.strategy!(Marshall.Accounts.User, :remember_me).cookie_name
           ) ==
             "__Host-remember_me"
  end

  # @cc [owner:ghuntley,label:security;verification] legacy-cookie-expiry-only-when-present
  # A request carrying the legacy remember_me cookie MUST receive an expiring
  # Set-Cookie for that name only; a request without it MUST receive none.
  test "the plug expires a legacy remember-me cookie only when the request carries it" do
    expired =
      conn(:get, "/")
      |> put_req_cookie("remember_me", "stale")
      |> put_req_cookie("_marshall_key", "current")
      |> BrowserSession.call([])
      |> send_resp(200, "")

    [header] = get_resp_header(expired, "set-cookie")

    assert header =~
             ~r/^remember_me=; path=\/; (expires=[^;]+; )?max-age=0; HttpOnly; SameSite=Lax$/

    clean = conn(:get, "/") |> BrowserSession.call([]) |> send_resp(200, "")
    assert get_resp_header(clean, "set-cookie") == []
  end
end
