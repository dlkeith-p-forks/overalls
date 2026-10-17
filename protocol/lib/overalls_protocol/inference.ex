defmodule OverallsProtocol.Inference do
  @moduledoc "Closed content-free inference control messages."
  @type result :: {:ok, map()} | {:error, :invalid_request}

  @spec admission(term()) :: result()
  def admission(value) when is_map(value) do
    binding = Map.take(value, ~w(host_id vm_id placement_id execution_epoch))

    with true <-
           Enum.sort(Map.keys(value)) ==
             Enum.sort(
               ~w(request_id host_id vm_id placement_id execution_epoch provider model operation)
             ),
         {:ok, parsed} <- OverallsProtocol.PrivateServices.binding(binding),
         true <- OverallsProtocol.uuid?(value["request_id"]),
         {:ok, provider} <- provider(value["provider"]),
         {:ok, operation} <- operation(provider, value["operation"]),
         true <- model?(value["model"]) do
      {:ok,
       Map.merge(parsed, %{
         id: value["request_id"],
         provider: provider,
         operation: operation,
         model: value["model"]
       })}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def admission(_), do: {:error, :invalid_request}

  # @cc [owner:ghuntley,label:security;accounting] inference-completion-no-content
  # Completion accepts only closed categorical outcomes and bounded numeric
  # metadata. Unknown usage MUST carry no fabricated counts. Extra fields,
  # negative counts and unbounded counts MUST fail before persistence.
  @spec completion(term()) :: result()
  def completion(value) when is_map(value) do
    with true <-
           Enum.sort(Map.keys(value) -- ["cost_estimate"]) ==
             Enum.sort(~w(outcome tokens completeness)),
         true <- cost?(value["cost_estimate"]),
         true <- is_nil(value["cost_estimate"]) or value["completeness"] == "complete",
         true <-
           value["outcome"] in ~w(completed upstream_error cancelled revoked transport_error interrupted),
         true <- value["completeness"] in ~w(complete partial unknown),
         true <- tokens?(value["tokens"]),
         true <- value["completeness"] != "unknown" or value["tokens"] == %{},
         true <- value["completeness"] != "complete" or map_size(value["tokens"]) > 0 do
      {:ok, value}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def completion(_), do: {:error, :invalid_request}

  @spec model?(term()) :: boolean()
  def model?(model) when is_binary(model),
    do: byte_size(model) in 1..256 and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._:\/-]*\z/, model)

  def model?(_), do: false
  defp provider("openai"), do: {:ok, :openai}
  defp provider("anthropic"), do: {:ok, :anthropic}
  defp provider(_), do: :error
  defp operation(:openai, "responses"), do: {:ok, :responses}
  defp operation(:openai, "chat"), do: {:ok, :chat}
  defp operation(:anthropic, "messages"), do: {:ok, :messages}
  defp operation(:anthropic, "count_tokens"), do: {:ok, :count_tokens}
  defp operation(_, _), do: :error
  defp cost?(nil), do: true

  defp cost?(
         %{
           "usd" => usd,
           "scope" => "tokens",
           "source" => "llmdb",
           "version" => version,
           "digest" => digest
         } = value
       )
       when map_size(value) == 5 and is_binary(usd) and is_binary(version) and is_binary(digest) do
    Regex.match?(~r/\A[0-9]{1,24}\.[0-9]{12}\z/, usd) and
      Regex.match?(~r/\A[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,3}\z/, version) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)
  end

  defp cost?(_), do: false

  defp tokens?(tokens) when is_map(tokens),
    do:
      Enum.all?(tokens, fn {key, value} ->
        key in ~w(input_tokens output_tokens total_tokens cached_input_tokens cache_creation_input_tokens reasoning_tokens) and
          count?(value)
      end)

  defp tokens?(_), do: false
  defp count?(n), do: is_integer(n) and n >= 0 and n <= 9_223_372_036_854_775_807
end
