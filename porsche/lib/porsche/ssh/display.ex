defmodule Porsche.SSH.Display do
  @moduledoc "Explicit PTY row layout for the channel-local editor."
  @prompt "porsche> "

  # @cc [owner:ghuntley,label:protocol] porsche-display-owned-rows
  # Redraw MUST return to the editor origin, erase its old rows and place the
  # cursor at the selected grapheme. The viewport MUST fit the PTY height and
  # follow the cursor; layout MUST avoid autowrap margins when width exceeds one.
  @spec clear(non_neg_integer() | nil) :: binary()
  def clear(nil), do: ""
  def clear(row), do: "\r" <> move(row, "A") <> "\e[J"

  @spec render(Porsche.SSH.Input.t(), pos_integer(), pos_integer()) ::
          {binary(), non_neg_integer()}
  def render(input, width, height \\ 24) do
    cells = max(width - 1, 1)

    prefix =
      @prompt <> (input.buffer |> String.graphemes() |> Enum.take(input.cursor) |> Enum.join())

    {_, {cursor_row, cursor_col}} = layout(prefix, cells)
    next = input.buffer |> String.graphemes() |> Enum.at(input.cursor)

    {cursor_row, cursor_col} =
      if next && cursor_col + min(cell_width(next), cells) > cells,
        do: {cursor_row + 1, 0},
        else: {cursor_row, cursor_col}

    {text, {_end_row, end_col}} = layout(@prompt <> input.buffer, cells)
    rows = String.split(text, "\r\n")
    offset = max(0, cursor_row - max(height - 1, 0))
    visible = Enum.slice(rows, offset, max(height, 1))
    text = Enum.join(visible, "\r\n")
    cursor_row = cursor_row - offset
    end_row = length(visible) - 1
    # The last visible row may precede the end of the full input.
    end_col = if offset + length(visible) < length(rows), do: -1, else: end_col

    {text <>
       if({cursor_row, cursor_col} == {end_row, end_col},
         do: "",
         else: "\r" <> move(end_row - cursor_row, "A") <> move(cursor_col, "C")
       ), cursor_row}
  end

  @spec submitted(binary(), pos_integer()) :: binary()
  def submitted(line, width), do: elem(layout(@prompt <> line, max(width - 1, 1)), 0) <> "\r\n"

  defp layout(text, columns) do
    {parts, position} =
      Enum.reduce(String.graphemes(text), {[], {0, 0}}, fn grapheme, {parts, {row, col}} ->
        grapheme = if grapheme == "\t", do: " ", else: grapheme
        grapheme = if cell_width(grapheme) > columns, do: "?", else: grapheme
        size = cell_width(grapheme)

        if col + size > columns do
          {[grapheme, "\r\n" | parts], {row + 1, size}}
        else
          {[grapheme | parts], {row, col + size}}
        end
      end)

    {parts |> Enum.reverse() |> IO.iodata_to_binary(), position}
  end

  # Common terminal wide characters and emoji occupy two cells; combining
  # marks remain attached to their base by String.graphemes/1.
  defp cell_width(grapheme) do
    <<point::utf8, _::binary>> = grapheme

    cond do
      String.match?(grapheme, ~r/^\p{M}+$/u) ->
        0

      point in 0x1100..0x115F or point in 0x2329..0x232A or
        point in 0x2E80..0xA4CF or point in 0xAC00..0xD7A3 or
        point in 0xF900..0xFAFF or point in 0xFE10..0xFE19 or
        point in 0xFE30..0xFE6F or point in 0xFF01..0xFF60 or
        point in 0xFFE0..0xFFE6 or point in 0x1F000..0x1FAFF or
        point in 0x20000..0x3FFFD or String.contains?(grapheme, "\uFE0F") ->
        2

      true ->
        1
    end
  end

  defp move(0, _), do: ""
  defp move(count, direction), do: "\e[#{count}#{direction}"
end
