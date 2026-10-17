defmodule Marshall.Agents.ContextPolicy do
  @moduledoc "Validated deployment policy for agent context limits and native maintenance."

  @type t :: %{input_token_limit: pos_integer() | nil, native_compaction_verified: boolean()}
  @type error :: :invalid_context_input_limit | :invalid_native_compaction_capability

  # @cc [owner:ghuntley,label:configuration;recovery] context-policy-explicit-capabilities
  # Absent input allowance MUST remain unknown and native compaction MUST default
  # to disabled. Invalid configured values MUST fail startup, never silently
  # enable native maintenance or invent a model context allowance.
  @spec from_env(%{String.t() => String.t()}) :: {:ok, t()} | {:error, error()}
  def from_env(environment) when is_map(environment) do
    with {:ok, limit} <-
           input_limit(Map.get(environment, "MARSHALL_AGENT_CONTEXT_INPUT_TOKEN_LIMIT")),
         {:ok, native} <-
           native_capability(Map.get(environment, "MARSHALL_AGENT_NATIVE_COMPACTION_VERIFIED")) do
      {:ok, %{input_token_limit: limit, native_compaction_verified: native}}
    end
  end

  @spec input_limit(term()) :: {:ok, pos_integer() | nil} | {:error, :invalid_context_input_limit}
  defp input_limit(nil), do: {:ok, nil}

  defp input_limit(value) when is_binary(value) and byte_size(value) in 1..10 do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 and limit <= 2_147_483_647 -> {:ok, limit}
      _ -> {:error, :invalid_context_input_limit}
    end
  end

  defp input_limit(_), do: {:error, :invalid_context_input_limit}

  @spec native_capability(term()) ::
          {:ok, boolean()} | {:error, :invalid_native_compaction_capability}
  defp native_capability(nil), do: {:ok, false}
  defp native_capability("false"), do: {:ok, false}
  defp native_capability("true"), do: {:ok, true}
  defp native_capability(_), do: {:error, :invalid_native_compaction_capability}
end
