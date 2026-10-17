defmodule Marshall.Agents.ContextPolicy do
  @moduledoc "Validated deployment policy for agent context limits and native maintenance."

  @type native_compaction_capability :: %{
          provider: :openai,
          model: String.t(),
          evidence_digest: String.t()
        }
  @type t :: %{
          input_token_limit: pos_integer() | nil,
          native_compaction_capabilities: [native_compaction_capability()]
        }

  @type error ::
          :invalid_context_input_limit
          | :invalid_native_compaction_capability
          | :native_compaction_requires_model_allowlist

  @max_native_capabilities 64
  @max_evidence_digest_bytes 128

  # @cc [owner:ghuntley,label:configuration;recovery] context-policy-explicit-capabilities
  # Absent input allowance MUST remain unknown and native compaction MUST default
  # to disabled. Native maintenance MUST be bound to an exact provider/model
  # allowlist entry carrying an operator-provided evidence digest. The legacy
  # global boolean MUST never enable native maintenance. Invalid configured
  # values MUST fail startup, never silently enable native maintenance or invent
  # a model context allowance.
  @spec from_env(%{String.t() => String.t()}) :: {:ok, t()} | {:error, error()}
  def from_env(environment) when is_map(environment) do
    with {:ok, limit} <-
           input_limit(Map.get(environment, "MARSHALL_AGENT_CONTEXT_INPUT_TOKEN_LIMIT")),
         :ok <-
           legacy_native_switch(Map.get(environment, "MARSHALL_AGENT_NATIVE_COMPACTION_VERIFIED")),
         {:ok, capabilities} <-
           native_capabilities(
             Map.get(environment, "MARSHALL_AGENT_NATIVE_COMPACTION_CAPABILITIES")
           ) do
      {:ok, %{input_token_limit: limit, native_compaction_capabilities: capabilities}}
    end
  end

  @doc "Returns true only for an exact provider/model capability receipt."
  @spec native_compaction_verified?(t() | map(), atom() | String.t(), String.t()) :: boolean()
  def native_compaction_verified?(policy, provider, model)
      when is_map(policy) and is_binary(model) do
    provider = if provider == "openai", do: :openai, else: provider

    policy
    |> Map.get(:native_compaction_capabilities, [])
    |> Enum.any?(fn
      %{provider: ^provider, model: ^model, evidence_digest: digest}
      when is_binary(digest) ->
        valid_model?(model) and valid_evidence_digest?(digest)

      _ ->
        false
    end)
  end

  def native_compaction_verified?(_, _, _), do: false

  @spec input_limit(term()) :: {:ok, pos_integer() | nil} | {:error, :invalid_context_input_limit}
  defp input_limit(nil), do: {:ok, nil}

  defp input_limit(value) when is_binary(value) and byte_size(value) in 1..10 do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 and limit <= 2_147_483_647 -> {:ok, limit}
      _ -> {:error, :invalid_context_input_limit}
    end
  end

  defp input_limit(_), do: {:error, :invalid_context_input_limit}

  @spec legacy_native_switch(term()) :: :ok | {:error, error()}
  defp legacy_native_switch(nil), do: :ok
  defp legacy_native_switch("false"), do: :ok
  defp legacy_native_switch("true"), do: {:error, :native_compaction_requires_model_allowlist}
  defp legacy_native_switch(_), do: {:error, :invalid_native_compaction_capability}

  @spec native_capabilities(term()) ::
          {:ok, [native_compaction_capability()]}
          | {:error, :invalid_native_compaction_capability}
  defp native_capabilities(nil), do: {:ok, []}

  defp native_capabilities(value) when is_binary(value) and byte_size(value) in 2..65_536 do
    with {:ok, entries} when is_list(entries) <- Jason.decode(value),
         true <- length(entries) <= @max_native_capabilities,
         {:ok, capabilities} <- parse_capabilities(entries) do
      {:ok, capabilities}
    else
      _ -> {:error, :invalid_native_compaction_capability}
    end
  end

  defp native_capabilities(_), do: {:error, :invalid_native_compaction_capability}

  @spec parse_capabilities([term()]) ::
          {:ok, [native_compaction_capability()]}
          | {:error, :invalid_native_compaction_capability}
  defp parse_capabilities(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case parse_capability(entry) do
        {:ok, capability} ->
          if Enum.any?(
               acc,
               &(&1.provider == capability.provider and &1.model == capability.model)
             ),
             do: {:halt, {:error, :invalid_native_compaction_capability}},
             else: {:cont, {:ok, [capability | acc]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, capabilities} -> {:ok, Enum.sort_by(capabilities, &{&1.provider, &1.model})}
      error -> error
    end
  end

  @spec parse_capability(term()) ::
          {:ok, native_compaction_capability()}
          | {:error, :invalid_native_compaction_capability}
  defp parse_capability(
         %{
           "provider" => "openai",
           "model" => model,
           "evidence_digest" => evidence_digest
         } = entry
       )
       when is_binary(model) and is_binary(evidence_digest) do
    with true <- Map.keys(entry) |> Enum.sort() == ~w(evidence_digest model provider),
         true <- valid_model?(model),
         true <- valid_evidence_digest?(evidence_digest) do
      {:ok, %{provider: :openai, model: model, evidence_digest: evidence_digest}}
    else
      _ -> {:error, :invalid_native_compaction_capability}
    end
  end

  defp parse_capability(_), do: {:error, :invalid_native_compaction_capability}

  @spec valid_model?(String.t()) :: boolean()
  defp valid_model?(model),
    do: byte_size(model) in 1..256 and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._:\/-]*\z/, model)

  @spec valid_evidence_digest?(String.t()) :: boolean()
  defp valid_evidence_digest?(digest),
    do:
      byte_size(digest) in 64..@max_evidence_digest_bytes and
        Regex.match?(~r/\A[a-f0-9]{64}\z/, digest)
end
