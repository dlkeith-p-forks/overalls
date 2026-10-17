defmodule OverallsProtocol.InferenceTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.Inference

  property "content and arbitrary fields never cross the completion boundary",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_464_411_972 do
    field =
      draw(
        "field",
        OverallsProtocol.TestGenerators.string(:alphanumeric, min_length: 1, max_length: 64)
      )

    assert {:error, :invalid_request} =
             Inference.completion(Map.put(completion(), "extra_" <> field, "synthetic content"))
  end

  property "out of range token counts fail before persistence",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_472_778_185 do
    count =
      draw(
        "count",
        one_of([
          integer(-100_000..-1),
          OverallsProtocol.TestGenerators.above_int64()
        ])
      )

    value = %{
      completion()
      | "completeness" => "partial",
        "tokens" => %{"input_tokens" => count}
    }

    assert {:error, :invalid_request} = Inference.completion(value)
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

  defp completion do
    %{
      "outcome" => "interrupted",
      "tokens" => %{},
      "completeness" => "unknown"
    }
  end
end
