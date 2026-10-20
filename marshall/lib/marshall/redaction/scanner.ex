defmodule Marshall.Redaction.Scanner do
  @moduledoc "Typed, text-only secret scanner used at ingress and during historical scrubs."

  @type finding :: %{rule: String.t(), count: non_neg_integer()}
  @type result :: %{value: String.t(), findings: [finding()]}

  @rules [
    {"github-token", ~r/\bgh[pousr]_[A-Za-z0-9_]{20,}\b/},
    {"openai-key", ~r/\bsk-[A-Za-z0-9]{20,}\b/},
    {"aws-access-key", ~r/\bAKIA[0-9A-Z]{16}\b/},
    {"private-key",
     ~r/-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----.*?(?:-----END(?: [A-Z0-9]+)* PRIVATE KEY-----|$)/s},
    {"jwt", ~r/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/}
  ]

  @spec profile_digest() :: String.t()
  def profile_digest, do: :crypto.hash(:sha256, inspect(@rules)) |> Base.encode16(case: :lower)

  @spec redact(String.t()) :: result()
  def redact(value) when is_binary(value) do
    {redacted, counts} =
      Enum.reduce(@rules, {value, %{}}, fn {rule, regex}, {text, found} ->
        count = length(Regex.scan(regex, text))
        next = Regex.replace(regex, text, "[REDACTED:#{rule}]")
        {next, if(count == 0, do: found, else: Map.update(found, rule, count, &(&1 + count)))}
      end)

    %{
      value: redacted,
      findings: Enum.map(counts, fn {rule, count} -> %{rule: rule, count: count} end)
    }
  end

  @spec redact_json(term()) :: {term(), [finding()]}
  def redact_json(value) when is_binary(value) do
    result = redact(value)
    {result.value, result.findings}
  end

  def redact_json(value) when is_list(value) do
    Enum.map_reduce(value, [], fn item, findings ->
      {redacted, nested} = redact_json(item)
      {redacted, findings ++ nested}
    end)
  end

  def redact_json(value) when is_map(value) do
    Enum.reduce(value, {%{}, []}, fn {key, item}, {result, findings} ->
      {redacted, nested} = redact_json(item)
      {Map.put(result, key, redacted), findings ++ nested}
    end)
  end

  def redact_json(value), do: {value, []}
end