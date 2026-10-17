defmodule OverallsAntithesis.SDK.Details do
  @moduledoc "Bounded privacy reviewed numeric context; no free form strings or payloads."
  @enforce_keys []
  defstruct observed_count: nil,
            unknown_count: nil,
            invalid_count: nil,
            accepted_count: nil,
            refused_count: nil,
            retry_count: nil,
            elapsed_ms: nil

  @type t :: %__MODULE__{
          observed_count: non_neg_integer() | nil,
          unknown_count: non_neg_integer() | nil,
          invalid_count: non_neg_integer() | nil,
          accepted_count: non_neg_integer() | nil,
          refused_count: non_neg_integer() | nil,
          retry_count: non_neg_integer() | nil,
          elapsed_ms: non_neg_integer() | nil
        }
  @max_value 1_000_000_000

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = details) do
    details
    |> Map.from_struct()
    |> Map.values()
    |> Enum.all?(fn value ->
      is_nil(value) or (is_integer(value) and value >= 0 and value <= @max_value)
    end)
  end

  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = details) do
    details
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
