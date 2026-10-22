defmodule Marshall.Artifacts.Markdown do
  @moduledoc "Markdown pages rendered to HTML with raw HTML escaped, only on the content origin."

  # @cc [owner:ghuntley,label:security] artifact-markdown-escaped
  # Markdown artifacts MUST be rendered with raw HTML escaped: inline HTML is
  # escaped by the transformer and verbatim HTML blocks are rewritten to
  # escaped preformatted text. Link and image URLs other than relative, http,
  # https and mailto are removed. The result is served only from the
  # sandboxed content origin.
  @spec render(binary(), String.t()) :: binary()
  def render(markdown, title) when is_binary(markdown) and is_binary(title) do
    {_status, ast, _messages} = Earmark.Parser.as_ast(markdown, smartypants: false)
    # Earmark's transform spec takes one node, so each top-level node renders alone.
    body = Enum.map_join(ast, &Earmark.Transform.transform(safe(&1), compact_output: true))

    """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{Plug.HTML.html_escape(title)}</title>
    <style>body{font:16px/1.5 ui-monospace,monospace;max-width:72ch;margin:1.5rem auto;padding:0 1rem}
    pre{overflow:auto}img{max-width:100%}@media (prefers-color-scheme:dark){body{background:#111;color:#eee}a{color:#9cf}}</style>
    </head><body>#{body}</body></html>
    """
  end

  @type ast_node :: String.t() | {String.t(), [{String.t(), String.t()}], [ast_node()], map()}

  @spec safe(ast_node()) :: ast_node()
  defp safe({tag, attributes, content, %{verbatim: true}}),
    do: {"pre", [], [verbatim(tag, attributes, content)], %{}}

  defp safe({tag, attributes, content, meta}),
    do: {tag, Enum.flat_map(attributes, &safe_attribute/1), Enum.map(content, &safe/1), meta}

  defp safe(text) when is_binary(text), do: text

  @spec verbatim(String.t(), [{String.t(), String.t()}], [ast_node()]) :: String.t()
  defp verbatim(tag, attributes, content) do
    rendered = Enum.map_join(attributes, "", fn {name, value} -> " #{name}=\"#{value}\"" end)
    inner = Enum.map_join(content, "\n", &text/1)
    "<#{tag}#{rendered}>#{inner}</#{tag}>"
  end

  @spec text(ast_node()) :: String.t()
  defp text(value) when is_binary(value), do: value
  defp text({tag, attributes, content, _meta}), do: verbatim(tag, attributes, content)

  @spec safe_attribute({String.t(), String.t()}) :: [{String.t(), String.t()}]
  defp safe_attribute({name, value}) when name in ["href", "src"] do
    case URI.parse(String.trim(value)).scheme do
      nil ->
        [{name, value}]

      scheme ->
        if String.downcase(scheme) in ["http", "https", "mailto"], do: [{name, value}], else: []
    end
  end

  defp safe_attribute(attribute), do: [attribute]
end
