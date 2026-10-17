defmodule Marshall.Agents.CompactionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Marshall.Agents.Compaction

  test "complete projected requests trigger by bytes, items or a known input allowance" do
    assert %{estimated_tokens: nil, token_limit: nil, trigger?: false} =
             Compaction.measure(request([user("hello")]))

    assert %{trigger?: true, estimated_tokens: estimate, token_limit: 100} =
             Compaction.measure(request([user(String.duplicate("a", 400))]), token_limit: 100)

    assert estimate >= 100
    assert Compaction.measure(request(List.duplicate(user("x"), 192))).trigger?
    assert Compaction.measure(request([user(String.duplicate("x", 196_608))])).trigger?
    refute Compaction.measure(request([user("x")]), token_limit: :unknown).trigger?
  end

  test "small contexts infer normally and manual maintenance does not fabricate a prompt" do
    body = request([user("only request")])
    assert {:inference, ^body} = Compaction.next(body)
    assert {:error, :nothing_to_compact} = Compaction.next(body, manual: true)
  end

  test "unknown native support uses tool-free summaries and keeps instructions outside generated state" do
    body = request([user("old objective"), assistant("old result"), user("continue")])
    assert {:compact, plan} = Compaction.next(body, manual: true)
    assert plan.kind == :summary
    assert plan.request["tools"] == []
    assert plan.request["tool_choice"] == "none"
    assert Compaction.request_allowed?(plan.request, :summary)
    refute Compaction.request_allowed?(plan.request, :native)
    assert plan.retained_input == [user("continue")]
    refute Jason.encode!(plan.request) =~ "canonical platform instructions"
    assert plan.source_digest == Compaction.digest(body["input"])

    assert {:ok, [%{"role" => "assistant", "content" => text}]} =
             Compaction.checkpoint_items(%{
               "kind" => "summary",
               "text" => "Completed exploration."
             })

    assert text =~ "Completed exploration."
  end

  test "explicitly verified native support emits one trigger over the ordinary Responses shape" do
    body = request([user("first"), assistant("done"), user("next")])
    assert {:ok, plan} = Compaction.prepare(body, native_verified?: true)
    assert plan.kind == :native
    assert plan.request["tools"] == []
    assert plan.request["tool_choice"] == "none"
    assert List.last(plan.request["input"]) == %{"type" => "compaction_trigger"}
    assert hd(plan.request["input"]) == hd(body["input"])
    assert Compaction.request_allowed?(plan.request, :native)
    refute Map.has_key?(plan.request, "messages")

    refute Compaction.request_allowed?(
             %{plan.request | "tools" => [%{"name" => "read_file"}]},
             :native
           )

    refute Compaction.request_allowed?(Map.delete(plan.request, "tool_choice"), :native)
  end

  test "only bounded completed purpose-specific output can become a checkpoint" do
    summary = completed([message("Finished initial checks; implement the remaining change.")])
    assert {:ok, %{"kind" => "summary"}} = Compaction.parse_response(summary, :summary)
    assert {:error, :invalid_compaction_response} = Compaction.parse_response(summary, :native)

    assert {:error, :invalid_compaction_response} =
             Compaction.parse_response(%{summary | "status" => "incomplete"}, :summary)

    for text <- ["", "   ", String.duplicate("x", 32_769)] do
      assert {:error, :invalid_compaction_response} =
               Compaction.parse_response(completed([message(text)]), :summary)
    end

    native = %{"type" => "compaction", "encrypted_content" => "opaque-retained-state"}

    assert {:ok, %{"kind" => "native", "items" => [^native]}} =
             Compaction.parse_response(completed([native]), :native)

    for output <- [
          [native, message("extra")],
          [Map.put(native, "encrypted_content", "")],
          [Map.put(native, "instructions", "forged")],
          [call("side-effect")]
        ] do
      assert {:error, :invalid_compaction_response} =
               Compaction.parse_response(completed(output), :native)

      assert {:error, :invalid_compaction_response} =
               Compaction.parse_response(completed(output), :summary)
    end
  end

  test "long active turns compact completed work while preserving their original user input" do
    body =
      request([user("implement"), call("first"), result("first"), call("last"), result("last")])

    assert {:ok, plan} = Compaction.prepare(body)
    assert plan.retained_input == [user("implement"), call("last"), result("last")]
    assert history(plan) == [call("first"), result("first")]
  end

  test "orphaned and incomplete tool groups refuse maintenance" do
    for input <- [
          [result("lost"), user("next")],
          [call("missing"), user("next")],
          [call("duplicate"), call("duplicate"), result("duplicate"), user("next")]
        ] do
      assert {:error, :invalid_context} = Compaction.prepare(request(input))
    end
  end

  test "oversized required user input refuses rather than silently dropping it" do
    assert {:error, :context_too_large} =
             Compaction.next(request([user("old"), user(String.duplicate("x", 262_144))]))
  end

  test "bounded batches retain every unprocessed group for another maintenance step" do
    input =
      Enum.map(1..8, &assistant(String.duplicate(Integer.to_string(&1), 50_000))) ++
        [user("next")]

    assert {:ok, plan} = Compaction.prepare(request(input))
    assert Compaction.fits?(plan.request)
    assert history(plan) ++ plan.retained_input == input
    assert length(plan.retained_input) > 1
  end

  test "checkpoint installation can reject no-progress output" do
    assert {:ok, plan} = Compaction.prepare(request([user("old"), user("next")]))

    refute Compaction.progress?(plan, %{"kind" => "summary", "text" => String.duplicate("x", 500)})

    assert Compaction.progress?(%{source_bytes: 1000, source_items: 3}, %{
             "kind" => "summary",
             "text" => "done"
           })
  end

  test "only definite closed provider errors authorize context-limit recovery" do
    assert Compaction.failure_reason(%{"error" => "context_length_exceeded"}) ==
             :context_limit_exceeded

    assert Compaction.failure_reason(%{"error" => %{"code" => "context_length_exceeded"}}) ==
             :context_limit_exceeded

    assert Compaction.failure_reason(%{"error" => %{"message" => "context_length_exceeded"}}) ==
             nil

    assert Compaction.failure_reason(%{"error" => %{"code" => "timeout"}}) == nil
    assert Compaction.failure_reason(%{"status" => "uncertain"}) == nil
  end

  property "completed tool groups are either entirely summarized or entirely retained" do
    check all(count <- integer(1..40), size <- integer(1..1000)) do
      groups =
        Enum.map(1..count, fn index ->
          id = Integer.to_string(index)
          [call(id), Map.put(result(id), "output", String.duplicate("x", size))]
        end)

      input = [user("objective")] ++ List.flatten(groups) ++ [user("continue")]
      assert {:ok, plan} = Compaction.prepare(request(input))
      compacted = history(plan)
      assert compacted ++ plan.retained_input == input

      for group <- groups do
        assert (Enum.all?(group, &(&1 in compacted)) and
                  Enum.all?(group, &(&1 not in plan.retained_input))) or
                 (Enum.all?(group, &(&1 in plan.retained_input)) and
                    Enum.all?(group, &(&1 not in compacted)))
      end
    end
  end

  @spec request([map()]) :: map()
  defp request(input),
    do: %{
      "model" => "test-model",
      "input" => [%{"role" => "system", "content" => "canonical platform instructions"} | input],
      "tools" => [%{"name" => "read_file"}],
      "store" => false,
      "stream" => true
    }

  @spec user(String.t()) :: map()
  defp user(text), do: %{"role" => "user", "content" => text}
  @spec assistant(String.t()) :: map()
  defp assistant(text), do: %{"role" => "assistant", "content" => text}
  @spec message(String.t()) :: map()
  defp message(text),
    do: %{"type" => "message", "content" => [%{"type" => "output_text", "text" => text}]}

  @spec call(String.t()) :: map()
  defp call(id),
    do: %{"type" => "function_call", "call_id" => id, "name" => "read_file", "arguments" => "{}"}

  @spec result(String.t()) :: map()
  defp result(id), do: %{"type" => "function_call_output", "call_id" => id, "output" => "done"}
  @spec completed([map()]) :: map()
  defp completed(output), do: %{"status" => "completed", "output" => output}
  @spec history(Compaction.plan()) :: [map()]
  defp history(plan),
    do: plan.request["input"] |> List.last() |> Map.fetch!("content") |> Jason.decode!()
end
