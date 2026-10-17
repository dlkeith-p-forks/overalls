defmodule OverallsAntithesis.SDK.Property do
  @moduledoc "A compile-time assertion descriptor with a stable string identity."
  @enforce_keys [:kind, :message, :module, :function, :file, :line]
  defstruct [:kind, :message, :module, :function, :file, :line]

  @type kind :: :always | :always_or_unreachable | :sometimes | :reachable | :unreachable
  @type t :: %__MODULE__{
          kind: kind(),
          message: binary(),
          module: binary(),
          function: binary(),
          file: binary(),
          line: pos_integer()
        }

  @spec wire(t(), boolean(), boolean(), OverallsAntithesis.SDK.Details.t() | nil) :: map()
  def wire(%__MODULE__{} = property, hit, condition, details) do
    {must_hit, assert_type, display_type} = kind_fields(property.kind)

    body = %{
      "hit" => hit,
      "must_hit" => must_hit,
      "assert_type" => assert_type,
      "display_type" => display_type,
      "message" => property.message,
      "condition" => condition,
      "id" => property.message,
      "location" => %{
        "class" => property.module,
        "function" => property.function,
        "file" => property.file,
        "begin_line" => property.line,
        "begin_column" => 0
      }
    }

    body =
      if hit and details != nil,
        do: Map.put(body, "details", OverallsAntithesis.SDK.Details.to_wire(details)),
        else: body

    %{"antithesis_assert" => body}
  end

  @spec kind_fields(kind()) :: {boolean(), binary(), binary()}
  defp kind_fields(:always), do: {true, "always", "Always"}
  defp kind_fields(:always_or_unreachable), do: {false, "always", "AlwaysOrUnreachable"}
  defp kind_fields(:sometimes), do: {true, "sometimes", "Sometimes"}
  defp kind_fields(:reachable), do: {true, "reachability", "Reachable"}
  defp kind_fields(:unreachable), do: {false, "reachability", "Unreachable"}
end
