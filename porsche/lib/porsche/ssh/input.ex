defmodule Porsche.SSH.Input do
  @moduledoc "Bounded, channel-local incremental command editor."
  defstruct buffer: "",
            cursor: 0,
            lines: [],
            cr: false,
            eof: false,
            utf8: "",
            escape: "",
            history: [],
            history_index: nil,
            draft: {"", 0}

  @type t :: %__MODULE__{
          buffer: binary(),
          cursor: non_neg_integer(),
          lines: [binary()],
          cr: boolean(),
          eof: boolean(),
          utf8: binary(),
          escape: binary(),
          history: [binary()],
          history_index: non_neg_integer() | nil,
          draft: {binary(), non_neg_integer()}
        }

  # @cc [owner:ghuntley,label:capacity;security] porsche-input-bounded-lines
  # Pending lines plus editable UTF-8 input MUST fit 8192 bytes. Escape sequences
  # MUST fit 64 bytes. Unsupported controls MUST NOT reach the command parser.
  # CRLF MUST submit exactly one line, including across packet boundaries.
  @spec feed(t(), binary()) :: {:ok, t(), [binary()]} | :close | :interrupt | {:error, atom()}
  def feed(state, bytes), do: feed(state, bytes, [])
  defp feed(state, <<>>, submitted), do: {:ok, state, Enum.reverse(submitted)}
  defp feed(_, <<3, _::binary>>, _), do: :interrupt
  defp feed(_, <<4, _::binary>>, _), do: :close

  defp feed(state, <<byte, rest::binary>>, submitted) do
    case consume(state, byte) do
      {:ok, next} -> continue(next, rest, submitted)
      {:line, line, next} -> continue(next, rest, [line | submitted])
      error -> error
    end
  end

  defp continue(state, rest, submitted) do
    if pending_bytes(state) <= 8192,
      do: feed(state, rest, submitted),
      else: {:error, :command_too_large}
  end

  @spec pending_bytes(t()) :: non_neg_integer()
  def pending_bytes(state),
    do:
      byte_size(state.buffer) + byte_size(state.utf8) +
        Enum.reduce(state.lines, 0, &(byte_size(&1) + 1 + &2))

  defp consume(%{escape: escape} = state, byte) when escape != "" do
    sequence = escape <> <<byte>>

    cond do
      byte_size(sequence) > 64 -> {:error, :invalid_input}
      escape == "\e" and byte in [?[, ?O] -> {:ok, %{state | escape: sequence}}
      escape == "\e" -> {:ok, %{state | escape: ""}}
      byte in 0x40..0x7E -> {:ok, arrow(%{state | escape: ""}, sequence)}
      byte in 0x20..0x3F -> {:ok, %{state | escape: sequence}}
      true -> {:ok, %{state | escape: ""}}
    end
  end

  defp consume(%{utf8: bytes} = state, byte) when bytes != "",
    do: unicode(state, bytes <> <<byte>>)

  defp consume(state, 27), do: {:ok, %{state | escape: "\e", cr: false}}
  defp consume(%{cr: true} = state, 10), do: {:ok, %{state | cr: false}}

  defp consume(state, byte) when byte in [10, 13] do
    line = state.buffer
    history = if line == "", do: state.history, else: trim_history([line | state.history])

    {:line, line,
     %{
       state
       | buffer: "",
         cursor: 0,
         lines: state.lines ++ [line],
         cr: byte == 13,
         history: history,
         history_index: nil,
         draft: {"", 0}
     }}
  end

  defp consume(state, byte) when byte in [8, 127] do
    graphemes = String.graphemes(state.buffer)

    buffer =
      if state.cursor == 0,
        do: state.buffer,
        else: List.delete_at(graphemes, state.cursor - 1) |> Enum.join()

    {:ok, %{state | buffer: buffer, cursor: max(0, state.cursor - 1), cr: false}}
  end

  defp consume(state, 9), do: insert(state, "\t")
  defp consume(state, byte) when byte >= 32, do: unicode(state, <<byte>>)
  defp consume(_, _), do: {:error, :invalid_input}

  defp unicode(state, bytes) do
    case :unicode.characters_to_binary(bytes) do
      text when is_binary(text) ->
        if String.match?(text, ~r/[\x{0080}-\x{009f}\x{2028}\x{2029}]/u),
          do: {:error, :invalid_input},
          else: insert(%{state | utf8: ""}, text)

      {:incomplete, _, _} ->
        {:ok, %{state | utf8: bytes, cr: false}}

      {:error, _, _} ->
        {:error, :invalid_input}
    end
  end

  defp insert(%{buffer: buffer, cursor: cursor} = state, <<byte>>)
       when byte in 32..126 and byte_size(buffer) == cursor do
    {:ok, %{state | buffer: buffer <> <<byte>>, cursor: cursor + 1, cr: false}}
  end

  defp insert(state, text) do
    {left, right} = Enum.split(String.graphemes(state.buffer), state.cursor)
    prefix = Enum.join(left) <> text
    buffer = prefix <> Enum.join(right)
    # A newly received combining character may join the preceding grapheme.
    cursor =
      buffer
      |> String.graphemes()
      |> Enum.scan(0, &(byte_size(&1) + &2))
      |> Enum.find_index(&(&1 >= byte_size(prefix)))
      |> Kernel.+(1)

    {:ok, %{state | buffer: buffer, cursor: cursor, cr: false}}
  end

  # @cc [owner:ghuntley,label:protocol;security] porsche-editor-submission-history
  # Cursor edits MUST preserve graphemes and never alter submitted lines. Recall
  # MUST NOT submit commands. History MUST remain channel-local, unlogged and
  # unpersisted, limited to 100 entries/65536 bytes, with Down restoring the draft.
  defp arrow(state, sequence) do
    case sequence do
      seq when seq in ["\e[A", "\eOA"] ->
        history(state, :up)

      seq when seq in ["\e[B", "\eOB"] ->
        history(state, :down)

      seq when seq in ["\e[C", "\eOC"] ->
        %{state | cursor: min(String.length(state.buffer), state.cursor + 1)}

      seq when seq in ["\e[D", "\eOD"] ->
        %{state | cursor: max(0, state.cursor - 1)}

      _ ->
        state
    end
  end

  defp history(%{history: []} = state, _), do: state
  defp history(%{history_index: nil} = state, :down), do: state

  defp history(%{history_index: 0, draft: {text, cursor}} = state, :down),
    do: %{state | buffer: text, cursor: cursor, history_index: nil}

  defp history(state, direction) do
    draft = if is_nil(state.history_index), do: {state.buffer, state.cursor}, else: state.draft

    index =
      case {state.history_index, direction} do
        {nil, :up} -> 0
        {index, :up} -> min(index + 1, length(state.history) - 1)
        {index, :down} -> index - 1
      end

    text = Enum.at(state.history, index)
    %{state | buffer: text, cursor: String.length(text), history_index: index, draft: draft}
  end

  defp trim_history(history) do
    history
    |> Enum.take(100)
    |> Enum.reduce_while({[], 0}, fn line, {acc, size} ->
      if size + byte_size(line) <= 65536,
        do: {:cont, {[line | acc], size + byte_size(line)}},
        else: {:halt, {acc, size}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec take(t()) :: {:line, binary(), t()} | :empty
  def take(%{lines: [line | rest]} = state), do: {:line, line, %{state | lines: rest}}

  def take(%{eof: true, buffer: line} = state) when line != "",
    do: {:line, line, %{state | buffer: "", cursor: 0}}

  def take(_), do: :empty

  # @cc [owner:ghuntley,label:protocol] porsche-input-eof
  # EOF MUST retain complete pending text for final submission, discard partial
  # UTF-8/escape bytes and never execute an incomplete recalled history entry.
  @spec finish(t()) :: t()
  def finish(state) do
    buffer = if is_nil(state.history_index), do: state.buffer, else: ""
    %{state | eof: true, buffer: buffer, utf8: "", escape: ""}
  end
end
