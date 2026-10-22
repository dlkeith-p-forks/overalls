defmodule Marshall.Artifacts.EditsPropertyTest do
  # @cc [owner:ghuntley,label:verification;correctness] artifact-edits-model
  # Edits MUST agree with a naive split-based model: all-or-none, ordered, with
  # the first failing index reported, and an applied unique edit MUST be
  # reversible by its inverse.
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Artifacts.Edits

  @alphabet ~w(a b c <p> </p> x)

  defp text, do: map(list_of(member_of(@alphabet), max_length: 24), &Enum.join/1)
  defp needle, do: map(list_of(member_of(@alphabet), min_length: 1, max_length: 3), &Enum.join/1)

  @spec model(String.t(), [Edits.edit()]) :: {:ok, String.t()} | {:error, atom(), map()}
  defp model(text, edits) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, text}, fn {%{old_str: old, new_str: new}, index}, {:ok, current} ->
      case String.split(current, old) do
        [before, rest] -> {:cont, {:ok, before <> new <> rest}}
        [_] -> {:halt, {:error, :edit_not_found, %{index: index}}}
        _ -> {:halt, {:error, :edit_ambiguous, %{index: index}}}
      end
    end)
  end

  property "edits agree with the split model" do
    original = draw("text", text())

    edits =
      draw(
        "edits",
        list_of(
          map(tuple({needle(), text()}), fn {old, new} -> %{old_str: old, new_str: new} end),
          min_length: 1,
          max_length: 5
        )
      )

    assert Edits.apply(original, edits) == model(original, edits)
  end

  property "a unique edit is undone by its inverse" do
    prefix = draw("prefix", text())
    suffix = draw("suffix", text())
    marker = "\u0000MARK\u0000"
    replacement = "\u0001NEW\u0001"
    source = prefix <> marker <> suffix

    assert {:ok, edited} = Edits.apply(source, [%{old_str: marker, new_str: replacement}])
    assert {:ok, ^source} = Edits.apply(edited, [%{old_str: replacement, new_str: marker}])
  end

  test "an empty old string never matches" do
    assert {:error, :edit_not_found, %{index: 0}} =
             Edits.apply("abc", [%{old_str: "", new_str: "x"}])
  end
end
