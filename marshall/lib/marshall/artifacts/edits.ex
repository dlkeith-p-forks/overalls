defmodule Marshall.Artifacts.Edits do
  @moduledoc "Exact, unique, ordered old/new string replacements applied all-or-none."

  @type edit :: %{old_str: String.t(), new_str: String.t()}
  @type refusal :: {:error, :edit_not_found | :edit_ambiguous, %{index: non_neg_integer()}}

  # @cc [owner:ghuntley,label:correctness] artifact-edits-all-or-none
  # Edits MUST apply in order, each against the text produced by the previous
  # edit. Each old_str MUST be non-empty and occur exactly once at its turn;
  # otherwise nothing is applied and the refusal names the zero-based index.
  @spec apply(String.t(), [edit()]) :: {:ok, String.t()} | refusal()
  def apply(text, edits) when is_binary(text) and is_list(edits) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, text}, fn {%{old_str: old, new_str: new}, index}, {:ok, current} ->
      case occurrences(current, old) do
        1 -> {:cont, {:ok, replace_once(current, old, new)}}
        0 -> {:halt, {:error, :edit_not_found, %{index: index}}}
        _ -> {:halt, {:error, :edit_ambiguous, %{index: index}}}
      end
    end)
  end

  @doc "Counts non-overlapping occurrences; an empty needle never matches."
  @spec occurrences(String.t(), String.t()) :: non_neg_integer()
  def occurrences(_text, ""), do: 0
  def occurrences(text, needle), do: text |> :binary.matches(needle) |> length()

  @spec replace_once(String.t(), String.t(), String.t()) :: String.t()
  defp replace_once(text, old, new) do
    [{start, length}] = :binary.matches(text, old)

    binary_part(text, 0, start) <>
      new <> binary_part(text, start + length, byte_size(text) - start - length)
  end
end
