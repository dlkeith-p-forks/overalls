defmodule MarshallLocalizationContractTest do
  use Covenant.Case, component: "marshall.web_surface"
  alias Marshall.Localization

  @tag obligation: "marshall.web_surface.I10"
  test "validated preferences determine locale and direction and responses vary by selection" do
    assert Localization.choose("ja", "ar", "fi") == "ja"
    assert Localization.choose(nil, nil, "fi;q=0.9, ja;q=0.1") == "fi"
    assert Localization.choose("../../x", nil, String.duplicate("x", 8193)) == "en"
    assert Localization.normalize(<<255>>) == nil
    assert Localization.direction("ar") == :rtl
    assert Localization.direction("ur") == :rtl
    assert Localization.direction("ja") == :ltr

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_req_header("accept-language", "ar")
      |> MarshallWeb.LocalePlug.call(session: true)

    assert conn.assigns.locale == "ar"
    assert conn.assigns.direction == :rtl
    assert Plug.Conn.get_resp_header(conn, "content-language") == ["ar"]
    assert Plug.Conn.get_resp_header(conn, "vary") == ["Accept-Language, Cookie"]
    assert Plug.Conn.get_session(conn, "locale") == "ar"
  end
end
