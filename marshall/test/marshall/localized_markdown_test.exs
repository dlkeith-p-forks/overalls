defmodule Marshall.LocalizedMarkdownTest do
  use ExUnit.Case, async: true
  alias Marshall.{Documentation, Handbook, LocalizedMarkdown}

  test "prose extraction preserves fenced command and diagram bytes" do
    source =
      "# Heading\n\nA paragraph.\n\n```porsche\nls --json\n\nrm example\n```\n\n```mermaid\ngraph TD\nA-->B\n```\n\nFinal paragraph.\n"

    units = LocalizedMarkdown.units(source)
    assert Enum.map_join(units, & &1.source) == source
    assert Enum.any?(units, &(&1.translatable? and &1.source == "# Heading"))
    refute Enum.any?(units, &(&1.translatable? and String.contains?(&1.source, "ls --json")))
    refute Enum.any?(units, &(&1.translatable? and String.contains?(&1.source, "A-->B")))
  end

  test "table cells and prose containing angle brackets enter the catalog" do
    table = "| State | Meaning |\n| --- | --- |\n| ready | Available |"
    prose = "Mail arrives from <noreply@example.invalid>."

    assert [%{source: ^table, translatable?: true}] = LocalizedMarkdown.units(table)
    assert [%{source: ^prose, translatable?: true}] = LocalizedMarkdown.units(prose)
  end

  test "locale selection is closed and chapter identifiers remain stable" do
    ids = Enum.map(Handbook.contents("en"), & &1.id)

    for locale <- LocalizedMarkdown.locales() do
      assert Enum.map(Handbook.contents(locale), & &1.id) == ids
      assert Enum.all?(Handbook.contents(locale), &(Enum.sort(Map.keys(&1)) == [:id, :title]))
      assert Handbook.fetch_chapter("../system", locale) == :error
      assert {:ok, %{slug: "index"}} = Documentation.page("index", locale)
      assert Documentation.page("../secrets", locale) == :error
    end

    assert Documentation.page("index", "../../secret") == Documentation.page("index", "en")
    assert Handbook.contents("unsupported") == Handbook.contents("en")
  end

  test "localized command references preserve every command and option token" do
    for locale <- LocalizedMarkdown.locales(), level <- [2, 3] do
      reference = LocalizedMarkdown.command_reference(locale, level)

      for command <- OverallsProtocol.SSHCommand.catalog() do
        assert reference =~ "`#{command.usage}`"
        assert reference =~ "#{String.duplicate("#", level)} `#{command.name}`"
        for option <- command.options, do: assert(reference =~ "`--#{option}`")
      end
    end
  end

  test "sentence punctuation around bare URLs follows the translated prose" do
    assert LocalizedMarkdown.valid_translation?(
             "Connect at https://example.invalid.",
             "https://example.invalid。で接続します。"
           )

    assert LocalizedMarkdown.valid_translation?(
             "Connect at https://example.invalid.",
             "接続先は https://example.invalid。"
           )

    refute LocalizedMarkdown.valid_translation?(
             "Connect at https://example.invalid.",
             "接続先は https://different.invalid。"
           )

    refute LocalizedMarkdown.valid_translation?(
             "Use `https://example.invalid.`",
             "Use `https://example.invalid`"
           )
  end

  test "multiline inline code remains exact while surrounding prose is translated" do
    source =
      "Configure `config :marshall, MarshallWeb.SecurityHeaders,\ndevelopment_tooling: true` and `localhost`."

    translated =
      "Määritä `config :marshall, MarshallWeb.SecurityHeaders,\ndevelopment_tooling: true` sekä `localhost`."

    assert LocalizedMarkdown.valid_translation?(source, translated)

    refute LocalizedMarkdown.valid_translation?(
             source,
             String.replace(translated, "development_tooling: true", "development_tooling: false")
           )

    refute LocalizedMarkdown.valid_translation?(
             source,
             String.replace(translated, "SecurityHeaders,\n", "SecurityHeaders, ")
           )
  end

  test "translated prose cannot change commands, links or heading structure" do
    assert LocalizedMarkdown.valid_translation?("# Commands", "# Befehle")

    assert LocalizedMarkdown.valid_translation?(
             "Run `help` at [docs](/docs).",
             "Exécutez `help` dans [documentation](/docs)."
           )

    refute LocalizedMarkdown.valid_translation?("Run `help`.", "Exécutez `rm`.")

    refute LocalizedMarkdown.valid_translation?(
             "Read [docs](/docs).",
             "Lisez [docs](https://example.invalid)."
           )

    refute LocalizedMarkdown.valid_translation?("# Commands", "Commands")
  end
end
