defmodule Marshall.Artifacts.MarkdownPropertyTest do
  # @cc [owner:ghuntley,label:security;verification] artifact-markdown-escape-property
  # Generated Markdown mixing block and inline HTML, script and event-handler
  # payloads and link schemes MUST render without any raw tag from the input
  # and without event-handler attributes or javascript: or data: URLs.
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Marshall.Artifacts.Markdown

  @fragments [
    "# Heading",
    "plain text",
    "<script>alert(1)</script>",
    "<img src=x onerror=alert(1)>",
    "<div onclick=\"x()\">block</div>",
    "inline <b onmouseover=x>bold</b>",
    "`<i>code</i>`",
    "[link](javascript:alert(1))",
    "[link](JaVaScRiPt:alert(1))",
    "![img](data:text/html,<script>x</script>)",
    "[ok](https://example.test/a)",
    "<iframe src=//evil.test></iframe>",
    "<svg/onload=alert(1)>"
  ]

  property "rendered markdown carries no raw input tags or script URLs" do
    parts = draw("parts", list_of(member_of(@fragments), min_length: 1, max_length: 8))
    html = Markdown.render(Enum.join(parts, "\n\n"), "Title")
    body = html |> String.split("<body>", parts: 2) |> List.last()

    for tag <- ["<script", "<div", "<b ", "<iframe", "<svg", "<i>"] do
      refute body =~ tag, "raw #{tag} in #{body}"
    end

    refute body =~ ~r/(href|src)="\s*(javascript|data):/i
    refute body =~ ~r/<[^>]*\son[a-z]+=/i
  end

  test "safe links and code survive" do
    html = Markdown.render("[ok](https://example.test/a)\n\n`<i>`", "T")
    assert html =~ ~s(<a href="https://example.test/a">ok</a>)
    assert html =~ "&lt;i&gt;"
  end
end
