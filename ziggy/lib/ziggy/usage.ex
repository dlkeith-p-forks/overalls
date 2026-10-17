defmodule Ziggy.Usage do
  @moduledoc "Bounded native usage extraction; content never leaves the parser."
  @enforce_keys [:provider, :mode]
  defstruct [:provider, :mode, buffer: "", discarded: false, tokens: %{}, complete: false]
  @type t :: %__MODULE__{}
  @limit 1_048_576
  @fields ~w(input_tokens output_tokens total_tokens cached_input_tokens cache_creation_input_tokens reasoning_tokens)

  @spec new(:openai | :anthropic, :sse | :json) :: t()
  def new(provider, mode), do: %__MODULE__{provider: provider, mode: mode}

  # @cc [owner:ghuntley,label:security;accounting] usage-parser-bounded-content-free
  # Arbitrary chunk boundaries MUST NOT alter extracted usage. Overlong frames
  # MUST be discarded without interrupting forwarding. Only bounded numeric
  # usage leaves this parser; absent fields remain absent and missing terminal
  # usage MUST NOT be reported as complete or replaced with zero.
  @spec feed(t(), binary()) :: t()
  def feed(%{mode: :json} = state, chunk) do
    if not state.discarded and byte_size(state.buffer) + byte_size(chunk) <= @limit,
      do: %{state | buffer: state.buffer <> chunk},
      else: %{state | buffer: "", discarded: true}
  end

  def feed(%{mode: :sse} = state, chunk) do
    # Normalize only complete lines, preserving CRLF split across network chunks.
    lines(state, chunk)
  end

  @spec finish(t()) :: %{tokens: map(), completeness: binary()}
  def finish(%{mode: :json, discarded: false} = state),
    do: result(decode(state, state.buffer, true))

  def finish(state), do: result(state)

  defp result(state),
    do: %{
      tokens: Map.take(state.tokens, @fields),
      completeness:
        if(state.complete,
          do: "complete",
          else: if(map_size(state.tokens) == 0, do: "unknown", else: "partial")
        )
    }

  defp lines(state, chunk) do
    case :binary.match(chunk, "\n") do
      :nomatch ->
        append(state, chunk)

      {offset, 1} ->
        <<line::binary-size(^offset), _newline, rest::binary>> = chunk
        state = append(state, line)

        state =
          if state.discarded,
            do: state,
            else: event_line(state, String.trim_trailing(state.buffer, "\r"))

        lines(%{state | buffer: "", discarded: false}, rest)
    end
  end

  defp append(state, chunk) do
    if not state.discarded and byte_size(state.buffer) + byte_size(chunk) <= @limit,
      do: %{state | buffer: state.buffer <> chunk},
      else: %{state | buffer: "", discarded: true}
  end

  defp event_line(state, "data: " <> json), do: decode(state, json, false)
  defp event_line(state, "data:" <> json), do: decode(state, json, false)
  defp event_line(state, _), do: state

  defp decode(state, json, terminal) do
    case Jason.decode(json) do
      {:ok, object} when is_map(object) -> extract(state, object, terminal)
      _ -> state
    end
  end

  defp extract(
         %{provider: :openai} = state,
         %{"type" => type, "response" => response},
         _
       )
       when type in [
              "response.completed",
              "response.incomplete",
              "response.failed",
              "response.cancelled",
              "response.canceled"
            ] and is_map(response),
       do: extract(state, response, true)

  defp extract(%{provider: :openai} = state, %{"choices" => [], "usage" => usage}, _)
       when is_map(usage), do: extract(state, %{"usage" => usage}, true)

  defp extract(%{provider: :openai} = state, %{"usage" => usage}, terminal) when is_map(usage) do
    tokens =
      %{}
      |> put("input_tokens", usage["input_tokens"] || usage["prompt_tokens"])
      |> put("output_tokens", usage["output_tokens"] || usage["completion_tokens"])
      |> put("total_tokens", usage["total_tokens"])
      |> put(
        "cached_input_tokens",
        nested(usage, "input_tokens_details", "cached_tokens") ||
          nested(usage, "prompt_tokens_details", "cached_tokens")
      )
      |> put(
        "reasoning_tokens",
        nested(usage, "output_tokens_details", "reasoning_tokens") ||
          nested(usage, "completion_tokens_details", "reasoning_tokens")
      )

    %{
      state
      | tokens: Map.merge(state.tokens, tokens),
        complete:
          terminal and Map.has_key?(tokens, "input_tokens") and
            Map.has_key?(tokens, "output_tokens")
    }
  end

  defp extract(
         %{provider: :anthropic} = state,
         %{"type" => "message_start", "message" => message},
         _
       )
       when is_map(message),
       do: anthropic(state, message["usage"], false)

  defp extract(
         %{provider: :anthropic} = state,
         %{"type" => "message_delta", "usage" => usage},
         _
       ),
       do: anthropic(state, usage, true)

  defp extract(%{provider: :anthropic} = state, %{"usage" => usage}, terminal),
    do: anthropic(state, usage, terminal)

  defp extract(%{provider: :anthropic} = state, %{"input_tokens" => tokens}, true),
    do: %{state | tokens: put(%{}, "input_tokens", tokens), complete: valid_count?(tokens)}

  defp extract(state, _, _), do: state

  defp anthropic(state, usage, terminal) when is_map(usage) do
    tokens =
      state.tokens
      |> put("input_tokens", usage["input_tokens"])
      |> put("output_tokens", usage["output_tokens"])
      |> put("cached_input_tokens", usage["cache_read_input_tokens"])
      |> put("cache_creation_input_tokens", usage["cache_creation_input_tokens"])

    %{
      state
      | tokens: tokens,
        complete:
          terminal and Map.has_key?(tokens, "input_tokens") and
            Map.has_key?(tokens, "output_tokens")
    }
  end

  defp anthropic(state, _, _), do: state
  defp nested(map, field, key), do: if(is_map(map[field]), do: map[field][key])
  defp put(map, key, value), do: if(valid_count?(value), do: Map.put(map, key, value), else: map)

  defp valid_count?(value),
    do: is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807
end
