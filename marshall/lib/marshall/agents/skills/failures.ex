defmodule Marshall.Agents.Skills.Failures do
  @moduledoc "Closed managed skill outcomes safe to persist as operational metadata."
  @values [
    :access_revoked,
    :machine_changed,
    :stale_operation,
    :invalid_result,
    :invalid_skill,
    :fetch_failed,
    :local_changes,
    :digest_mismatch,
    :operation_conflict,
    :unsupported_guest,
    :unavailable,
    :uncertain
  ]

  @spec values() :: [atom()]
  def values, do: @values

  @spec normalize(term()) :: atom()
  def normalize(value) when value in @values, do: value

  def normalize(value) when is_binary(value),
    do: Enum.find(@values, :unavailable, &(Atom.to_string(&1) == value))

  def normalize(_), do: :unavailable
end
