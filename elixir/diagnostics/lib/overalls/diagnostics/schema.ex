defmodule Overalls.Diagnostics.Schema do
  @moduledoc false
  @external_resource Path.expand("../../../priv/trace-schema.json", __DIR__)
  @schema @external_resource |> File.read!() |> Jason.decode!()
  @enum_values MapSet.new(Map.fetch!(@schema, "enum_values"))

  @spec attributes(:uuid | :enum | :number) :: [binary()]
  def attributes(:uuid), do: @schema["uuid_attributes"]
  def attributes(:enum), do: @schema["enum_attributes"]
  def attributes(:number), do: @schema["numeric_attributes"]

  @spec enum?(atom()) :: boolean()
  def enum?(value) when is_atom(value), do: MapSet.member?(@enum_values, Atom.to_string(value))

  @spec uuid?(term()) :: boolean()
  def uuid?(value) when is_binary(value) do
    case String.split(value, "-") do
      [a, b, c, d, e] ->
        byte_size(a) == 8 and byte_size(b) == 4 and byte_size(c) == 4 and
          byte_size(d) == 4 and byte_size(e) == 12 and
          Enum.all?([a, b, c, d, e], &hex_part?/1)

      _ ->
        false
    end
  end

  def uuid?(_), do: false

  @spec hex_part?(binary()) :: boolean()
  defp hex_part?(part), do: part != "" and String.match?(part, ~r/\A[0-9A-Fa-f]+\z/)
end
