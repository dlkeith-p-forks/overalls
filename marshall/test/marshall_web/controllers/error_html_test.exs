defmodule MarshallWeb.ErrorHTMLTest do
  use MarshallWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    html = render_to_string(MarshallWeb.ErrorHTML, "404", "html", [])

    assert html
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("h1")
           |> LazyHTML.text() == "Not Found"

    refute html =~ "Field notes"
    refute html =~ "Appearance"
  end

  test "renders 400-series pages without navigation" do
    html = render_to_string(MarshallWeb.ErrorHTML, "400", "html", [])

    assert html =~ "Bad Request"
    refute html =~ "Field notes"
    refute html =~ "Appearance"
  end

  test "renders 500.html" do
    html = render_to_string(MarshallWeb.ErrorHTML, "500", "html", [])

    assert html
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("h1")
           |> LazyHTML.text() == "Internal Server Error"

    refute html =~ "Field notes"
    refute html =~ "Appearance"
  end

  test "all standard error headings have literal extraction identities and preserve English" do
    identities =
      :marshall
      |> Application.app_dir("priv/gettext/errors.pot")
      |> Expo.PO.parse_file!()
      |> Map.fetch!(:messages)
      |> MapSet.new(&IO.iodata_to_binary(&1.msgid))

    Gettext.with_locale(MarshallWeb.Gettext, "en", fn ->
      for {code, source} <- known_error_statuses() do
        assert MapSet.member?(identities, source), "Unextracted HTTP #{code} heading: #{source}"
        html = render_to_string(MarshallWeb.ErrorHTML, Integer.to_string(code), "html", [])
        document = LazyHTML.from_document(html)
        assert document |> LazyHTML.query("h1") |> LazyHTML.text() == source
      end
    end)
  end

  test "Arabic and Japanese error pages localize headings and declare their active direction" do
    for {locale, direction} <- [{"ar", "rtl"}, {"ja", "ltr"}] do
      Gettext.with_locale(MarshallWeb.Gettext, locale, fn ->
        for code <- [400, 403, 404, 500, 503] do
          source = Plug.Conn.Status.reason_phrase(code)
          heading = Gettext.dgettext(MarshallWeb.Gettext, "errors", source)
          refute heading == source
          html = render_to_string(MarshallWeb.ErrorHTML, Integer.to_string(code), "html", [])
          document = LazyHTML.from_document(html)

          assert document |> LazyHTML.query("h1") |> LazyHTML.text() == heading

          assert Enum.count(
                   LazyHTML.query(document, "html[lang='#{locale}'][dir='#{direction}']")
                 ) == 1
        end
      end)
    end
  end

  test "a server error retries itself only while the database does not answer" do
    answering = render_to_string(MarshallWeb.ErrorHTML, "500", "html", [])
    refute answering =~ ~s(http-equiv="refresh")
    refute render_to_string(MarshallWeb.ErrorHTML, "404", "html", []) =~ "refresh"

    # A bare process has no sandbox allowance, so it has no database.
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:unavailable, Marshall.Repo.answers?(),
         render_to_string(MarshallWeb.ErrorHTML, "500", "html", [])}
      )
    end)

    assert_receive {:unavailable, false, unavailable}, 5_000
    assert unavailable =~ ~s(http-equiv="refresh")
    assert unavailable =~ "retry automatically"
    refute render_to_string(MarshallWeb.ErrorHTML, "404", "html", []) =~ "refresh"
  end

  @spec known_error_statuses() :: [{pos_integer(), String.t()}]
  defp known_error_statuses do
    Enum.flat_map(400..599, fn code ->
      try do
        [{code, Plug.Conn.Status.reason_phrase(code)}]
      rescue
        ArgumentError -> []
      end
    end)
  end
end
