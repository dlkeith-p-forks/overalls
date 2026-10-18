defmodule Marshall.Handbook do
  @moduledoc "Release-packaged, reviewed design and operations handbook."

  for catalog <-
        Path.wildcard(Path.expand("../../priv/gettext/*/LC_MESSAGES/documentation.po", __DIR__)) do
    @external_resource catalog
  end

  @type chapter :: %{id: String.t(), title: String.t(), html: String.t()}
  @type summary :: %{id: String.t(), title: String.t()}
  @directory Path.expand("../../priv/hldd", __DIR__)
  @paths Path.wildcard(Path.join(@directory, "[0-9]*.md")) |> Enum.sort()
  if @paths == [], do: raise("HLDD chapters are missing")

  @variants Map.new(Marshall.LocalizedMarkdown.locales(), fn locale ->
              chapters =
                Enum.map(@paths, fn path ->
                  @external_resource path
                  [_, id] = Regex.run(~r/^[0-9]+-(.+)\.md$/, Path.basename(path))

                  markdown =
                    File.read!(path)
                    |> Marshall.LocalizedMarkdown.translate(locale)
                    |> String.replace(
                      "{{COMMAND_REFERENCE}}",
                      Marshall.LocalizedMarkdown.command_reference(locale, 3)
                    )

                  [_, title] = Regex.run(~r/^# (.+)$/m, markdown)

                  markdown =
                    Regex.replace(~r/\]\(repo:([^\s)]+)\)/, markdown, fn _, target ->
                      "](https://github.com/ghuntley/overalls/blob/trunk/#{target})"
                    end)

                  markdown = Regex.replace(~r/\]\(#([a-z][a-z0-9-]*)\)/, markdown, "](/hldd/\\1)")

                  {:ok, html, []} = Earmark.as_html(markdown, escape: true, smartypants: false)
                  %{id: id, title: title, html: html}
                end)

              {locale,
               %{
                 contents: Enum.map(chapters, &Map.take(&1, [:id, :title])),
                 by_id: Map.new(chapters, &{&1.id, &1})
               }}
            end)

  # @cc [owner:ghuntley,label:performance] handbook-contents-metadata
  # The contents catalog MUST contain only section identifiers and titles, never
  # section bodies. Opening the index MUST NOT preload the complete handbook.
  @spec contents(term()) :: [summary()]
  def contents(locale \\ Gettext.get_locale(MarshallWeb.Gettext)),
    do: Map.fetch!(@variants, Marshall.LocalizedMarkdown.locale(locale)).contents

  # @cc [owner:ghuntley,label:security] handbook-compiled-content
  # Handbook HTML MUST originate only from the compiled chapter catalog. Request
  # values and live domain data MUST NOT select files or enter trusted HTML.
  @spec fetch_chapter(String.t(), term()) :: {:ok, chapter()} | :error
  def fetch_chapter(id, locale \\ Gettext.get_locale(MarshallWeb.Gettext)),
    do:
      @variants
      |> Map.fetch!(Marshall.LocalizedMarkdown.locale(locale))
      |> Map.fetch!(:by_id)
      |> Map.fetch(id)

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?,
    do: Enum.sort(Path.wildcard(Path.join(@directory, "[0-9]*.md"))) != @paths
end
