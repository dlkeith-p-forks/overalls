defmodule MarshallWeb.TerminalNamesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias MarshallWeb.TerminalNames

  property "names are deterministic, lower-case adjective-noun pairs" do
    check all(id <- StreamData.string(:printable, min_length: 1, max_length: 64)) do
      name = TerminalNames.display_name(id)
      assert name == TerminalNames.display_name(id)
      assert name =~ ~r/^[a-z]+-[a-z]+$/
    end
  end

  test "different sessions usually receive different names" do
    names = Enum.map(1..64, fn _ -> TerminalNames.display_name(Ash.UUID.generate()) end)
    assert length(Enum.uniq(names)) > 48
  end
end
