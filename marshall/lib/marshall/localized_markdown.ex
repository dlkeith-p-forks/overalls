defmodule Marshall.LocalizedMarkdown do
  @moduledoc "Compiled documentation localization units, preserving fenced examples and diagrams."

  @type unit :: %{source: String.t(), translatable?: boolean()}
  @type structure :: %{String.t() => pos_integer()}
  @structural_tags ~w(code em h1 h2 h3 h4 h5 h6 li ol strong ul)
  @max_prose_bytes 65_536
  @locales ~w(en zh-Hans hi es ar fr bn pt-BR pt-PT ru ur id de ja pcm mr te tr ta vi ko fil et fi sv arz sw ha)

  @spec locales() :: [String.t()]
  def locales, do: @locales

  @spec locale(term()) :: String.t()
  def locale(value) when value in @locales, do: value
  def locale(_), do: "en"

  # @cc [owner:ghuntley,label:security] documentation-literal-boundary
  # Fenced command examples and diagrams MUST remain byte-identical. Only reviewed
  # source prose enters the documentation catalog; request values never supply it.
  @spec units(String.t()) :: [unit()]
  def units(markdown) do
    {units, _fence} =
      markdown
      |> String.split(~r/(\n\s*\n)/, include_captures: true, trim: false)
      |> Enum.map_reduce(nil, fn block, fence ->
        lines = String.split(block, "\n")

        {next, fenced?} =
          Enum.reduce(lines, {fence, not is_nil(fence)}, fn line, {open, seen} ->
            case Regex.run(~r/^\s*(`{3,}|~{3,})/, line) do
              [_, marker] when is_nil(open) -> {String.first(marker), true}
              [_, marker] -> if String.first(marker) == open, do: {nil, true}, else: {open, seen}
              nil -> {open, seen}
            end
          end)

        prose? =
          not fenced? and String.trim(block) != "" and
            not String.contains?(block, "{{COMMAND_REFERENCE}}")

        {%{source: block, translatable?: prose?}, next}
      end)

    units
  end

  @spec translate(String.t(), String.t()) :: String.t()
  def translate(markdown, requested_locale) do
    locale = locale(requested_locale)

    Gettext.with_locale(MarshallWeb.Gettext, locale, fn ->
      markdown
      |> units()
      |> Enum.map_join(fn
        %{source: source, translatable?: true} ->
          translated = Gettext.dgettext(MarshallWeb.Gettext, "documentation", source)
          if valid_translation?(source, translated), do: translated, else: source

        %{source: source} ->
          source
      end)
    end)
  end

  @doc "Localized command prose with command syntax preserved byte for byte."
  @spec command_reference(String.t(), 2 | 3) :: String.t()
  def command_reference(requested_locale, level) when level in [2, 3] do
    Gettext.with_locale(MarshallWeb.Gettext, locale(requested_locale), fn ->
      Enum.map_join(OverallsProtocol.SSHCommand.catalog(), "\n\n", fn command ->
        heading = String.duplicate("#", level)
        summary = Gettext.dgettext(MarshallWeb.Gettext, "documentation", command.summary)
        options = Gettext.dgettext(MarshallWeb.Gettext, "documentation", "Options:")

        "#{heading} `#{command.name}`\n\n`#{command.usage}`\n\n#{summary}\n\n#{options} " <>
          Enum.map_join(command.options, ", ", &"`--#{&1}`") <> "."
      end)
    end)
  end

  # @cc [owner:ghuntley,label:security] localized-markdown-protected-tokens
  # Translated prose MUST preserve the exact multiset of inline code spans,
  # including spans crossing line breaks, and link destinations from its source.
  # Parsed emphasis, list types/items, headings and code spans MUST also remain
  # present; prose order and paragraph wrapping MAY change with the language.
  @spec valid_translation?(String.t(), String.t()) :: boolean()
  def valid_translation?(source, translated) do
    protected(source) == protected(translated) and
      heading_prefix(source) == heading_prefix(translated) and
      same_structure?(source, translated)
  end

  @spec same_structure?(String.t(), String.t()) :: boolean()
  defp same_structure?(source, translated) do
    with {:ok, expected} <- structure(source),
         {:ok, actual} <- structure(translated) do
      expected == actual
    else
      :error -> false
    end
  end

  @spec structure(String.t()) :: {:ok, structure()} | :error
  defp structure(value) when byte_size(value) <= @max_prose_bytes do
    # Earmark 1.4.49 incorrectly specifies its AST as binary(). Capture the
    # public parser at this foreign boundary; its result remains untrusted until
    # structure_nodes/2 validates every node recursively. Remove this boundary
    # when the pinned dependency correctly specifies its list-shaped AST.
    parser = Function.capture(Earmark, :as_ast!, 1)
    structure_nodes(parser.(value), %{})
  rescue
    Earmark.Error -> :error
  end

  defp structure(_value), do: :error

  @spec structure_nodes(term(), structure()) :: {:ok, structure()} | :error
  defp structure_nodes([], counts), do: {:ok, counts}

  defp structure_nodes([node | remaining], counts) do
    with {:ok, next} <- structure_node(node, counts) do
      structure_nodes(remaining, next)
    end
  end

  defp structure_nodes(_nodes, _counts), do: :error

  @spec structure_node(term(), structure()) :: {:ok, structure()} | :error
  defp structure_node(text, counts) when is_binary(text), do: {:ok, counts}

  defp structure_node({tag, attributes, children, metadata}, counts)
       when is_binary(tag) and is_list(attributes) and is_map(metadata) do
    counts =
      if tag in @structural_tags,
        do: Map.update(counts, tag, 1, &(&1 + 1)),
        else: counts

    with {:ok, next} <- structure_nodes(children, counts),
         true <- emphasis_edges?(tag, children) do
      {:ok, next}
    else
      _ -> :error
    end
  end

  defp structure_node(_node, _counts), do: :error

  @spec emphasis_edges?(String.t(), term()) :: boolean()
  defp emphasis_edges?(tag, children) when tag in ["strong", "em"] do
    case visible_text(children) do
      {:ok, text} -> text != "" and String.trim(text) == text
      :error -> false
    end
  end

  defp emphasis_edges?(_tag, _children), do: true

  @spec visible_text(term()) :: {:ok, String.t()} | :error
  defp visible_text([]), do: {:ok, ""}
  defp visible_text(text) when is_binary(text), do: {:ok, text}

  defp visible_text({tag, attributes, children, metadata})
       when is_binary(tag) and is_list(attributes) and is_map(metadata),
       do: visible_text(children)

  defp visible_text([node | remaining]) do
    with {:ok, first} <- visible_text(node),
         {:ok, rest} <- visible_text(remaining) do
      {:ok, first <> rest}
    end
  end

  defp visible_text(_nodes), do: :error

  @spec protected(String.t()) :: [String.t()]
  defp protected(value) do
    Regex.scan(~r/`[^`]+`|\]\([^\s)]+\)|https?:\/\/[^\s)>。！？、，؛؟]+/u, value)
    |> List.flatten()
    |> Enum.map(fn token ->
      if String.starts_with?(token, ["https://", "http://"]),
        do: Regex.replace(~r/[.,;:!?。！？，、؛؟]+$/u, token, ""),
        else: token
    end)
    |> Enum.sort()
  end

  @spec heading_prefix(String.t()) :: String.t() | nil
  defp heading_prefix(value) do
    case Regex.run(~r/^(\#{1,6}) /, value) do
      [_, prefix] -> prefix
      nil -> nil
    end
  end
end
