defmodule Marshall.HandbookTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
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

  property "unknown identifiers cannot select files or unlisted chapters" do
    ids = MapSet.new(Handbook.contents(), & &1.id)

    check all(id <- string(:utf8, max_length: 200), id not in ids) do
      assert Handbook.fetch_chapter(id) == :error
      assert Handbook.fetch_chapter("../" <> id) == :error
    end
  end
end
