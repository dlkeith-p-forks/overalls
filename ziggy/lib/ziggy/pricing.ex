defmodule Ziggy.Pricing do
  @moduledoc "Non-billing token-only estimates with pinned catalog provenance."
  @spec estimate(:openai | :anthropic, binary(), map()) :: map() | nil
  def estimate(provider, id, %{completeness: "complete", tokens: tokens}) do
    with {:ok, model} <- LLMDB.model({provider, id}),
         cost when is_map(cost) <- model.cost,
         {:ok, amount} <- token_cost(provider, tokens, cost),
         digest when is_binary(digest) <- get_in(LLMDB.snapshot(), [:meta, :digest]),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) do
      %{
        "usd" => :erlang.float_to_binary(amount * 1.0, decimals: 12),
        "scope" => "tokens",
        "source" => "llmdb",
        "version" => to_string(Application.spec(:llm_db, :vsn)),
        "digest" => digest
      }
    else
      _ -> nil
    end
  end

  def estimate(_, _, _), do: nil

  # @cc [owner:ghuntley,label:accounting] token-price-no-double-counting
  # OpenAI cached input is a subset of input; Anthropic cache creation/read are
  # separate categories. Missing rates for reported billable categories MUST
  # produce unknown cost. Reasoning is included in output and MUST NOT be added
  # a second time. Estimates cover tokens only, never provider tool fees.
  @spec token_cost(:openai | :anthropic, map(), map()) :: {:ok, number()} | :unknown
  def token_cost(provider, tokens, rates) do
    input = tokens["input_tokens"]
    output = tokens["output_tokens"]
    cached = tokens["cached_input_tokens"] || 0
    written = tokens["cache_creation_input_tokens"] || 0
    reasoning = tokens["reasoning_tokens"] || 0
    input = if is_integer(input) and provider == :openai, do: input - cached, else: input
    reasoning_rate = rates[:reasoning] || rates[:output]

    with true <-
           Enum.all?([input, output, cached, written, reasoning], &(is_integer(&1) and &1 >= 0)),
         true <- reasoning <= output,
         {:ok, a} <- component(input, rates[:input]),
         {:ok, b} <- component(output - reasoning, rates[:output]),
         {:ok, c} <- component(cached, rates[:cache_read]),
         {:ok, d} <- component(written, rates[:cache_write]),
         {:ok, e} <- component(reasoning, reasoning_rate) do
      {:ok, (a + b + c + d + e) / 1_000_000}
    else
      _ -> :unknown
    end
  end

  defp component(0, _), do: {:ok, 0}

  defp component(count, rate) when is_number(rate) and rate >= 0 and rate <= 1_000_000,
    do: {:ok, count * rate}

  defp component(_, _), do: :unknown
end
