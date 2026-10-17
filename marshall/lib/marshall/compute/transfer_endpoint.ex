defmodule Marshall.Compute.TransferEndpoint do
  @moduledoc "Validated persisted SSH endpoint identity, absent for hosts not enrolled for transfer."
  use Ash.Type

  @impl true
  def storage_type(_), do: :map

  # @cc [owner:ghuntley,label:security] enrolled-transfer-identity-remains-closed
  # Input, database loads and persistence MUST use the shared endpoint validator.
  # Nil means unavailable for relocation; it MUST NOT trigger key discovery or
  # construction of a default endpoint.
  @impl true
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(value, _) do
    case OverallsProtocol.TransferSSH.endpoint(value) do
      {:ok, endpoint} -> {:ok, endpoint}
      {:error, :invalid_transfer_endpoint} -> :error
    end
  end

  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)

  @impl true
  def dump_to_native(value, constraints), do: cast_input(value, constraints)
end
