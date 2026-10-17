defmodule OverallsProtocol.MachineName do
  @moduledoc "Shared machine names, distinct from UUID references."
  @pattern ~r/\A(?![0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z)[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/

  @spec pattern() :: Regex.t()
  def pattern, do: @pattern

  # @cc [owner:ghuntley,label:protocol] machine-name-unambiguous-reference
  # Names MUST be bounded lowercase labels and MUST NOT be UUID-shaped, so a
  # machine reference cannot name one VM while identifying another VM's UUID.
  @spec valid?(term()) :: boolean()
  def valid?(name) when is_binary(name) and byte_size(name) in 1..63,
    do: Regex.match?(@pattern, name)

  def valid?(_), do: false

  @spec generated(binary()) :: binary()
  def generated(uuid) do
    if not OverallsProtocol.uuid?(uuid), do: raise(ArgumentError, "expected a machine UUID")
    "vm-" <> (uuid |> String.downcase() |> String.replace("-", ""))
  end
end
