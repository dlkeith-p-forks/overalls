defmodule Marshall.Compute.TransferDescriptor do
  @moduledoc "Validated source snapshot evidence, stored independently of execution authority."
  use Ash.Type
  @impl true
  def storage_type(_), do: :map

  # @cc [owner:ghuntley,label:security] transfer-descriptor-storage-validation
  # Input, stored and dumped values MUST be nil or the closed v3 descriptor.
  # Nil means no observed snapshot; it MUST NOT fabricate native GUID evidence.
  @impl true
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(value, _) do
    case OverallsProtocol.Relocation.descriptor(value) do
      {:ok, descriptor} -> {:ok, OverallsProtocol.Relocation.encode_descriptor(descriptor)}
      _ -> :error
    end
  end

  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)
  @impl true
  def dump_to_native(value, constraints), do: cast_input(value, constraints)
end
