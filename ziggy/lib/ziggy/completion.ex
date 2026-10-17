defmodule Ziggy.Completion do
  @moduledoc "Private completion diagnostics retained by Ziggy, outside control documents."

  # @cc [owner:ghuntley,label:security;recovery] ziggy-local-completion-closed
  # Local spool recovery MUST validate the entire completion before replay or SLO
  # counting. Duration, byte counts, provider IDs and status MUST remain local;
  # only the validated `wire/1` projection (outcome, tokens, completeness and
  # cost estimate) may cross Marshall's wire boundary.
  @spec validate(term()) :: {:ok, map()} | {:error, :invalid_request}
  def validate(value) when is_map(value) do
    with true <-
           Enum.sort(Map.keys(value) -- ~w(cost_estimate provider_request_id http_status)) ==
             Enum.sort(~w(outcome tokens completeness duration_ms request_bytes response_bytes)),
         {:ok, _} <-
           value
           |> wire()
           |> OverallsProtocol.Inference.completion(),
         true <- identifier?(value["provider_request_id"]),
         true <-
           is_nil(value["http_status"]) or
             (is_integer(value["http_status"]) and value["http_status"] in 100..599),
         true <-
           Enum.all?(~w(duration_ms request_bytes response_bytes), fn key ->
             is_nil(value[key]) or
               (is_integer(value[key]) and value[key] in 0..9_223_372_036_854_775_807)
           end) do
      {:ok, value}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def validate(_), do: {:error, :invalid_request}

  # @cc [owner:ghuntley,label:security;accounting] ziggy-completion-wire-projection
  # The wire document MUST contain only Marshall's closed accounting fields of a
  # validated local completion, preserving absent cost and unknown usage. It
  # MUST NOT reinterpret, fill or drop accounting values.
  @spec wire(map()) :: map()
  def wire(completion), do: Map.take(completion, ~w(outcome tokens completeness cost_estimate))

  @spec identifier?(term()) :: boolean()
  defp identifier?(nil), do: true

  defp identifier?(value) when is_binary(value),
    do: byte_size(value) in 1..256 and Regex.match?(~r/\A[a-zA-Z0-9._:\/-]+\z/, value)

  defp identifier?(_), do: false
end
