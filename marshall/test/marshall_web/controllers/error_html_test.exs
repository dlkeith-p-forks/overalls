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
end
