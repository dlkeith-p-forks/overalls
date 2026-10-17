defmodule Ziggy.PricingTest do
  use ExUnit.Case, async: true

  test "cached input and reasoning are not charged twice" do
    tokens = %{
      "input_tokens" => 100,
      "cached_input_tokens" => 40,
      "output_tokens" => 50,
      "reasoning_tokens" => 20
    }

    rates = %{input: 2, output: 4, cache_read: 1}
    assert {:ok, value} = Ziggy.Pricing.token_cost(:openai, tokens, rates)
    assert_in_delta value, (60 * 2 + 40 + 50 * 4) / 1_000_000, 1.0e-12
    assert {:ok, anthropic} = Ziggy.Pricing.token_cost(:anthropic, tokens, rates)
    assert_in_delta anthropic, (100 * 2 + 40 + 50 * 4) / 1_000_000, 1.0e-12
  end

  test "missing price or usage cannot manufacture zero cost" do
    assert :unknown =
             Ziggy.Pricing.token_cost(:openai, %{"input_tokens" => 1, "output_tokens" => 1}, %{})

    assert nil ==
             Ziggy.Pricing.estimate(:openai, "unknown-future-model", %{
               completeness: "unknown",
               tokens: %{}
             })
  end
end
