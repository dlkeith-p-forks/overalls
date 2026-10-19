defmodule Marshall.Handbook do
  @moduledoc "Release-packaged, reviewed design and operations handbook."

  @type chapter :: %{id: String.t(), title: String.t(), html: String.t()}
  @type summary :: %{id: String.t(), title: String.t()}
  @directory Path.expand("../../priv/hldd", __DIR__)
  @paths Path.wildcard(Path.join(@directory, "[0-9]*.md")) |> Enum.sort()
  if @paths == [], do: raise("HLDD chapters are missing")

  @command_reference Enum.map_join(OverallsProtocol.SSHCommand.catalog(), "\n\n", fn command ->
                       "### `#{command.name}`\n\n`#{command.usage}`\n\n#{command.summary}\n\nOptions: " <>
                         Enum.map_join(command.options, ", ", &"`--#{&1}`") <> "."
                     end)

  @chapters Enum.map(@paths, fn path ->
              @external_resource path
              [_, id] = Regex.run(~r/^[0-9]+-(.+)\.md$/, Path.basename(path))

              markdown =
                path
                |> File.read!()
                |> String.replace("{{COMMAND_REFERENCE}}", @command_reference)

              [_, title] = Regex.run(~r/^# (.+)$/m, markdown)

              markdown =
                Regex.replace(~r/\]\(repo:([^\s)]+)\)/, markdown, fn _, target ->
                  "](https://github.com/ghuntley/overalls/blob/trunk/#{target})"
                end)

              markdown = Regex.replace(~r/\]\(#([a-z][a-z0-9-]*)\)/, markdown, "](/hldd/\\1)")

              {:ok, html, []} = Earmark.as_html(markdown, escape: true, smartypants: false)
              %{id: id, title: title, html: html}
            end)
  @contents Enum.map(@chapters, &Map.take(&1, [:id, :title]))
  @by_id Map.new(@chapters, &{&1.id, &1})

  # @cc [owner:ghuntley,label:performance] handbook-contents-metadata
  # The contents catalog MUST contain only section identifiers and titles, never
  # section bodies. Opening the index MUST NOT preload the complete handbook.
  @spec contents() :: [summary()]
  def contents, do: @contents

  # @cc [owner:ghuntley,label:security] handbook-compiled-content
  # Handbook HTML MUST originate only from the compiled chapter catalog. Request
  # values and live domain data MUST NOT select files or enter trusted HTML.

  # @cc [owner:ghuntley,label:product] handbook-source-language
  # Chapter titles, prose and generated command summaries MUST remain source
  # English and MUST NOT depend on the reader's locale or translation catalogs.
  @spec fetch_chapter(String.t()) :: {:ok, chapter()} | :error
  def fetch_chapter(id), do: Map.fetch(@by_id, id)

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?,
    do: Enum.sort(Path.wildcard(Path.join(@directory, "[0-9]*.md"))) != @paths
end
