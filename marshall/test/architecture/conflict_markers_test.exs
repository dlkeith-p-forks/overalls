Code.require_file("../../../scripts/conflict_markers.ex", __DIR__)

defmodule Overalls.ConflictMarkersTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Overalls.ConflictMarkers

  @markers ["<<<<<<< HEAD", "<<<<<<<", "||||||| base", ">>>>>>> origin/main", ">>>>>>>"]

  # @cc [owner:ghuntley,label:verification;governance] conflict-marker-detection-oracle
  # Generated files MUST report exactly the lines that begin with an opening,
  # base or closing conflict marker, and MUST NOT report Markdown underlines,
  # indented or embedded marker text.
  property "reports exactly the lines that start with a conflict marker" do
    lines =
      draw(
        "lines",
        list_of(
          one_of([
            member_of(@markers),
            member_of(["=======", "Heading", "  <<<<<<< indented", "a >>>>>>> b", ""]),
            string(:printable, max_length: 20)
          ]),
          max_length: 30
        )
      )

    expected =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> Regex.match?(~r/\A(<{7}|\|{7}|>{7})( |\z)/, line) end)
      |> Enum.map(fn {_, number} -> {"f", number} end)

    assert ConflictMarkers.scan("f", Enum.join(lines, "\n")) == expected
  end

  test "the historical broken fleet module is refused and Markdown underlines are not" do
    broken =
      "<<<<<<< HEAD\n{ a ? false }:\n=======\n{ b ? false }:\n>>>>>>> origin/verify/112\nlet\n"

    assert ConflictMarkers.scan("default.nix", broken) == [{"default.nix", 1}, {"default.nix", 5}]
    assert ConflictMarkers.scan("README.md", "Title\n=======\n\ntext\r\n") == []
    assert ConflictMarkers.scan("crlf.nix", "ok\r\n>>>>>>> theirs\r\n") == [{"crlf.nix", 2}]
  end
end
