defmodule Porsche.SSH.DisplayTest do
  use ExUnit.Case, async: true
  alias Porsche.SSH.{Display, Input}

  test "redraw clears owned rows and positions an edited wrapped cursor" do
    {:ok, input, _} = Input.feed(%Input{}, "abcdefghij" <> String.duplicate("\e[D", 5))
    assert {"porsche> abcde\r\nfghij\r", 1} = Display.render(input, 15)
    assert Display.clear(2) == "\r\e[2A\e[J"
    assert Display.clear(nil) == ""
    assert {"porsche> abcdefghij\r\e[14C", 0} = Display.render(input, 80)
  end

  test "combining marks, CJK and emoji retain graphemes in wrapped output" do
    {:ok, input, _} = Input.feed(%Input{}, "é猫👩‍💻")
    assert {"porsche> é猫\r\n👩‍💻", 1} = Display.render(input, 13)
    assert Display.submitted("é猫👩‍💻", 13) == "porsche> é猫\r\n👩‍💻\r\n"
  end

  test "a long editable line uses a viewport bounded by terminal height" do
    {:ok, input, _} = Input.feed(%Input{}, String.duplicate("x", 100))
    {text, row} = Display.render(input, 15, 3)
    assert row == 2
    assert length(String.split(text, "\r\n")) == 3
    {:ok, input, _} = Input.feed(input, String.duplicate("\e[D", 100))
    {text, row} = Display.render(input, 15, 3)
    assert row == 0
    assert String.starts_with?(text, "porsche> ")
    assert String.ends_with?(text, "\r\e[2A\e[9C")
  end

  test "tabs preserve command bytes but render without terminal tab stops" do
    {:ok, input, _} = Input.feed(%Input{}, "a\tb")
    assert input.buffer == "a\tb"
    assert {"porsche> a b", 0} = Display.render(input, 80)
  end
end
