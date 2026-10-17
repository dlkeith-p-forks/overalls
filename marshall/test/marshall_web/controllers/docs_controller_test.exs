defmodule MarshallWeb.DocsControllerTest do
  use MarshallWeb.ConnCase
  import Hegel
  import Hegel.Gen
  alias Marshall.Documentation
  alias OverallsProtocol.SSHCommand

  test "public HTML and Markdown share packaged content without login or cookies" do
    for page <- Documentation.pages() do
      path = if page.slug == "index", do: "/docs", else: "/docs/#{page.slug}"
      html_conn = get(build_conn(), path)
      document = html_conn |> html_response(200) |> LazyHTML.from_document()
      assert LazyHTML.query(document, "#public-documentation h1") |> Enum.count() == 1

      assert LazyHTML.query(document, "link[rel=alternate][type='text/markdown']") |> Enum.count() ==
               1

      assert LazyHTML.query(document, "select[data-appearance]") |> Enum.count() == 1
      assert LazyHTML.query(document, "meta[name=csrf-token]") |> Enum.empty?()
      assert get_resp_header(html_conn, "set-cookie") == []
      assert get_resp_header(html_conn, "x-content-type-options") == ["nosniff"]

      markdown_conn =
        build_conn() |> put_req_header("accept", "text/markdown") |> get(path <> ".md")

      assert response(markdown_conn, 200) == page.markdown
      assert get_resp_header(markdown_conn, "content-type") == ["text/markdown; charset=utf-8"]
      assert get_resp_header(markdown_conn, "set-cookie") == []
    end
  end

  test "LLM index links resolve to Markdown and ignores supplied identity" do
    conn = build_conn() |> put_req_header("cookie", "account=synthetic") |> get("/llms.txt")
    index = response(conn, 200)
    assert index == Documentation.llms()
    links = Regex.scan(~r/\]\((\/[^)]+\.md)\)/, index, capture: :all_but_first)
    assert length(links) == length(Documentation.pages())

    for [path] <- links do
      assert String.starts_with?(build_conn() |> get(path) |> response(200), "# ")
    end
  end

  test "Browser extension guide advertises both developer downloads and setup limits" do
    html_conn = get(build_conn(), "/docs/browser-extension")
    document = html_conn |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(document, "#public-documentation h1") |> Enum.count() == 1
    assert LazyHTML.query(document, "a[href='/bin/chrome.zip']") |> Enum.count() == 1
    assert LazyHTML.query(document, "a[href='/bin/firefox.xpi']") |> Enum.count() == 1

    content = html_conn.resp_body
    assert content =~ "Load unpacked"
    assert content =~ "about:debugging"
    assert content =~ "Load Temporary Add-on"
    assert content =~ "HTTPS"
    assert content =~ "unsigned"
    assert content =~ "marks the open Overalls page as installed"
    assert content =~ "does not sign you in"

    for provider <- ~w(GitHub GitLab Codeberg Bitbucket), do: assert(content =~ provider)

    {:ok, page} = Documentation.page("browser-extension")
    markdown_conn = build_conn() |> get("/docs/browser-extension.md")
    assert response(markdown_conn, 200) == page.markdown
    assert Documentation.llms() =~ "](/docs/browser-extension.md)"
  end

  test "documentation cannot select other release files or repeat extensions" do
    for path <- [
          "/docs/CONTRACTS",
          "/docs/runtime.exs",
          "/docs/quickstart.md.md",
          "/docs/unknown"
        ] do
      assert build_conn() |> get(path) |> response(404) == "Documentation not found\n"
    end
  end

  test "every catalog command appears and every command example parses" do
    {:ok, page} = Documentation.page("commands")

    for command <- SSHCommand.catalog() do
      assert page.markdown =~ "## #{command.name}\n"
      assert page.markdown =~ "`#{command.usage}`"
    end

    examples =
      Documentation.pages()
      |> Enum.flat_map(
        &Regex.scan(~r/```porsche\n(.*?)```/s, &1.markdown, capture: :all_but_first)
      )
      |> Enum.flat_map(fn [block] -> String.split(block, "\n", trim: true) end)

    assert length(examples) >= 15
    for example <- examples, do: assert({:ok, _} = SSHCommand.parse(example))
  end

  property "arbitrary page selectors cannot read or render arbitrary content" do
    check all(selector <- term()) do
      case Documentation.page(selector) do
        {:ok, page} -> assert page in Documentation.pages()
        :error -> refute selector in Enum.map(Documentation.pages(), & &1.slug)
      end
    end
  end
end
