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
