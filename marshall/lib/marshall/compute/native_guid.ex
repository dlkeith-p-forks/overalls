defmodule Marshall.Compute.NativeGuid do
  @moduledoc "Canonical native ZFS GUID evidence, independent of source filesystem identity."
  use Ash.Type
  @impl true
  def storage_type(_), do: :string
  # @cc [owner:ghuntley,label:security] native-guid-canonical-evidence
  # Stored/input GUIDs MUST be nil or canonical bounded ZFS GUID strings. Nil
  # means no native observation; it MUST NOT fabricate ownership or receipt.
  @impl true
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(value, _),
    do: if(OverallsProtocol.Storage.guid?(value), do: {:ok, value}, else: :error)

  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)
  @impl true
  def dump_to_native(value, constraints), do: cast_input(value, constraints)
end
