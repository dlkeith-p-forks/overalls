defmodule Marshall.Documentation do
  @moduledoc "Release-packaged public documentation with a catalog-derived reference."

  @sources [
    {"index", "Overalls documentation"},
    {"browser-extension", "Browser extension"},
    {"quickstart", "Getting started"},
    {"commands", "Command reference"},
    {"automation", "Automation"}
  ]

  for {slug, _title} <- @sources do
    @external_resource Path.expand("../../priv/docs/#{slug}.md", __DIR__)
  end

  @reference Enum.map_join(OverallsProtocol.SSHCommand.catalog(), "\n\n", fn command ->
               "## #{command.name}\n\n`#{command.usage}`\n\n#{command.summary}\n\n" <>
                 "Options: " <>
                 Enum.map_join(command.options, ", ", &"`--#{&1}`") <> "."
             end)

  @pages Map.new(@sources, fn {slug, title} ->
           markdown =
             Path.expand("../../priv/docs/#{slug}.md", __DIR__)
             |> File.read!()
             |> String.replace("{{COMMAND_REFERENCE}}", @reference)

           {:ok, html, []} = Earmark.as_html(markdown, escape: true, smartypants: false)
           {slug, %{slug: slug, title: title, markdown: markdown, html: html}}
         end)

  # @cc [owner:ghuntley,label:security] docs-closed-public-pages
  # Request values MUST select only the compiled page catalog. They MUST NOT be
  # interpolated into filesystem paths, Markdown, HTML or live domain queries.
  @spec page(term()) :: {:ok, map()} | :error
  def page(slug), do: Map.fetch(@pages, slug)

  @spec pages() :: [map()]
  def pages, do: Enum.map(@sources, fn {slug, _} -> Map.fetch!(@pages, slug) end)

  @spec llms() :: binary()
  def llms do
    "# Overalls\n\n" <>
      "> Public documentation for Overalls browser extensions and SSH machine management (Porsche v1).\n\n" <>
      "## Documentation\n\n" <>
      Enum.map_join(pages(), "\n", fn page ->
        path = if page.slug == "index", do: "/docs.md", else: "/docs/#{page.slug}.md"
        "- [#{page.title}](#{path})"
      end) <> "\n"
  end
end
