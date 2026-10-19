defmodule Marshall.HandbookTest do
  use ExUnit.Case, async: true
  require Hegel
  alias Marshall.Handbook

  test "contents contains metadata only and every identifier selects one compiled body" do
    for summary <- Handbook.contents() do
      assert Enum.sort(Map.keys(summary)) == [:id, :title]
      assert {:ok, chapter} = Handbook.fetch_chapter(summary.id)
      assert chapter.id == summary.id
      assert chapter.title == summary.title
      assert is_binary(chapter.html)
      refute chapter.html =~ ~s(href="#)
    end
  end

  test "source titles and command help remain English in every reader locale" do
    contents = Handbook.contents()
    chapters = Map.new(contents, &{&1.id, Handbook.fetch_chapter(&1.id)})

    for locale <- Marshall.Localization.supported_locales() do
      Gettext.with_locale(MarshallWeb.Gettext, locale, fn ->
        assert Handbook.contents() == contents

        for {id, chapter} <- chapters do
          assert Handbook.fetch_chapter(id) == chapter
        end
      end)
    end

    for path <- Path.wildcard(Application.app_dir(:marshall, "priv/hldd/[0-9]*.md")) do
      [_, id] = Regex.run(~r/^[0-9]+-(.+)\.md$/, Path.basename(path))
      [_, title] = Regex.run(~r/^# (.+)$/m, File.read!(path))
      assert {:ok, %{title: ^title}} = Handbook.fetch_chapter(id)
    end

    {:ok, reference} = Handbook.fetch_chapter("reference")
    text = reference.html |> LazyHTML.from_document() |> LazyHTML.text()

    for command <- OverallsProtocol.SSHCommand.catalog() do
      assert text =~ command.summary
    end

    assert text =~ "Options:"
    refute reference.html =~ "{{COMMAND_REFERENCE}}"
  end

  @tag :hegel
  test "unknown identifiers cannot select files or unlisted chapters" do
    ids = MapSet.new(Handbook.contents(), & &1.id)
    unknown_id = Hegel.Gen.filter(Hegel.Gen.utf8(0, 200), &(not MapSet.member?(ids, &1)))

    Hegel.check(
      fn test_case ->
        :hegel.note(test_case, "unknown_id = <redacted>")
        id = :hegel.draw_silent(test_case, unknown_id)
        assert Handbook.fetch_chapter(id) == :error
        assert Handbook.fetch_chapter("../" <> id) == :error
      end,
      test_cases: 100,
      seed: 20_261_018,
      database: :disabled,
      print_blob: false
    )
  end
end
