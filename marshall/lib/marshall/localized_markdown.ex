defmodule Marshall.LocalizedMarkdown do
  @moduledoc "Compiled documentation localization units, preserving fenced examples and diagrams."

  @type unit :: %{source: String.t(), translatable?: boolean()}
  @locales ~w(en zh-Hans hi es ar fr bn pt-BR pt-PT ru ur id de ja pcm mr te tr ta vi ko fil et fi sv)

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
  @spec valid_translation?(String.t(), String.t()) :: boolean()
  def valid_translation?(source, translated) do
    protected(source) == protected(translated) and
      heading_prefix(source) == heading_prefix(translated)
  end

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
