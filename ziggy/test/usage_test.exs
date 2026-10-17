defmodule Ziggy.UsageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Ziggy.Usage

  @anthropic "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12,\"output_tokens\":0}}}\r\n\r\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7}}\r\n\r\n"

  property "native usage survives every generated transport partition" do
    check all(size <- integer(1..byte_size(@anthropic))) do
      chunks = for <<chunk::binary-size(^size) <- @anthropic>>, do: chunk
      consumed = length(chunks) * size
      chunks = chunks ++ [binary_part(@anthropic, consumed, byte_size(@anthropic) - consumed)]

      usage =
        Enum.reduce(chunks, Usage.new(:anthropic, :sse), &Usage.feed(&2, &1)) |> Usage.finish()

      assert usage == %{
               tokens: %{"input_tokens" => 12, "output_tokens" => 7},
               completeness: "complete"
             }
    end
  end

  test "missing usage is unknown; partial Anthropic usage is not completed" do
    assert %{tokens: %{}, completeness: "unknown"} = Usage.finish(Usage.new(:openai, :sse))

    state =
      Usage.feed(
        Usage.new(:anthropic, :sse),
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12,\"output_tokens\":0}}}\n"
      )

    assert %{completeness: "partial"} = Usage.finish(state)
  end

  test "malformed or oversized content is discarded while later usage remains observable" do
    state =
      Usage.new(:openai, :sse)
      |> Usage.feed("data: " <> :binary.copy("x", 1_048_577) <> "\n\n")
      |> Usage.feed(
        "data: {\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4},\"choices\":[]}\n\n"
      )

    assert state.buffer == ""

    assert %{tokens: %{"input_tokens" => 3, "output_tokens" => 4}, completeness: "complete"} =
             Usage.finish(state)
  end

  test "nonterminal usage cannot establish completion" do
    state =
      Usage.new(:openai, :sse)
      |> Usage.feed(
        ~s(data: {"type":"response.in_progress","usage":{"input_tokens":3,"output_tokens":4}}\n\n)
      )

    assert %{completeness: "partial"} = Usage.finish(state)

    state =
      Usage.feed(
        state,
        ~s(data: {"type":"response.completed","response":{"usage":{"input_tokens":3,"output_tokens":9}}}\n\n)
      )

    assert %{completeness: "complete", tokens: %{"output_tokens" => 9}} = Usage.finish(state)
  end

  test "only numeric usage escapes; native content and negative counts do not" do
    state =
      Usage.new(:openai, :json)
      |> Usage.feed(
        ~s({"secret":"synthetic body", "usage":{"input_tokens":4,"output_tokens":-1,"prompt":"synthetic"}})
      )

    assert %{tokens: %{"input_tokens" => 4}, completeness: "partial"} = Usage.finish(state)
  end

  property "terminal compaction failures retain numeric usage without inventing absent counts" do
    check all(
            type <-
              member_of([
                "response.completed",
                "response.failed",
                "response.incomplete",
                "response.cancelled"
              ]),
            usage <-
              member_of([
                nil,
                %{"input_tokens" => 9},
                %{"input_tokens" => 9, "output_tokens" => 4}
              ])
          ) do
      response = if is_nil(usage), do: %{}, else: %{"usage" => usage}
      event = %{"type" => type, "response" => Map.put(response, "private", "synthetic-body")}
      bytes = "data: " <> Jason.encode!(event) <> "\r\n\r\n"
      result = Usage.new(:openai, :sse) |> Usage.feed(bytes) |> Usage.finish()

      expected =
        case usage do
          nil -> %{tokens: %{}, completeness: "unknown"}
          %{"output_tokens" => _} -> %{tokens: usage, completeness: "complete"}
          _ -> %{tokens: usage, completeness: "partial"}
        end

      assert result == expected
      refute inspect(result) =~ "synthetic-body"
    end
  end
end
