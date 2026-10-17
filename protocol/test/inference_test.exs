defmodule OverallsProtocol.InferenceTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.Inference

  property "content and arbitrary fields never cross the completion boundary" do
    check all(field <- string(:alphanumeric, min_length: 1, max_length: 64)) do
      assert {:error, :invalid_request} =
               Inference.completion(Map.put(completion(), "extra_" <> field, "synthetic content"))
    end
  end

  property "out of range token counts fail before persistence" do
    check all(
            count <-
              one_of([
                integer(-100_000..-1),
                integer(9_223_372_036_854_775_807..9_223_372_036_854_775_807)
              ])
          ) do
      value = %{
        completion()
        | "completeness" => "partial",
          "tokens" => %{"input_tokens" => count}
      }

      assert {:error, :invalid_request} = Inference.completion(value)
    end
  end

  test "unknown cannot contain fabricated zero counts and complete requires counts" do
    assert {:ok, _} = Inference.completion(completion())

    assert {:error, _} =
             Inference.completion(%{completion() | "tokens" => %{"input_tokens" => 0}})

    assert {:error, _} = Inference.completion(%{completion() | "completeness" => "complete"})
  end

  test "diagnostics stay outside the accounting wire document" do
    for field <- ~w(duration_ms request_bytes response_bytes provider_request_id http_status) do
      assert {:error, :invalid_request} =
               Inference.completion(Map.put(completion(), field, nil))
    end
  end

  test "estimate requires exact provenance and decimal precision" do
    cost = %{
      "usd" => "0.000000000001",
      "scope" => "tokens",
      "source" => "llmdb",
      "version" => "2026.9.3",
      "digest" => String.duplicate("a", 64)
    }

    assert {:error, _} = Inference.completion(Map.put(completion(), "cost_estimate", cost))
    measured = %{completion() | "completeness" => "complete", "tokens" => %{"input_tokens" => 1}}
    assert {:ok, _} = Inference.completion(Map.put(measured, "cost_estimate", cost))

    assert {:error, _} =
             Inference.completion(
               Map.put(completion(), "cost_estimate", %{cost | "usd" => "NaN"})
             )
  end

  defp completion,
    do: %{
      "outcome" => "interrupted",
      "tokens" => %{},
      "completeness" => "unknown"
    }
end
