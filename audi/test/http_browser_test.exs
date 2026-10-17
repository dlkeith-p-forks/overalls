defmodule Audi.HTTP.BrowserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Audi.HTTP.Browser

  property "return destinations remain local paths" do
    check all(path <- string(:alphanumeric, max_length: 200)) do
      assert Browser.return_path?("/" <> path <> "?q=value")

      for invalid <- [
            "//" <> path,
            "https://" <> path,
            "/\\" <> path,
            "/_audi/" <> path,
            "/" <> path <> "\r\n"
          ] do
        refute Browser.return_path?(invalid)
      end
    end
  end

  test "duplicate platform cookies cannot choose a browser identity" do
    cookie = "audi_web_cookie_" <> Base.url_encode64(<<0::256>>, padding: false)

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("cookie", "__Host-audi_session=" <> cookie)

    assert {:ok, ^cookie} = Browser.credential(conn)

    conn =
      Plug.Conn.put_req_header(
        conn,
        "cookie",
        "__Host-audi_session=" <> cookie <> "; __Host-audi_session=" <> cookie
      )

    assert :error = Browser.credential(conn)
    assert :error = Browser.credential(Plug.Test.conn(:get, "/"))
  end

  test "an invalid callback returns no credential and forbids referrers" do
    conn = Plug.Test.conn(:get, "/_audi/callback?ticket=invalid&code=invalid")
    result = Browser.callback(conn, nil)
    assert result.status == 403
    assert Plug.Conn.get_resp_header(result, "referrer-policy") == ["no-referrer"]
    refute Map.has_key?(result.resp_cookies, "__Host-audi_session")
  end
end
