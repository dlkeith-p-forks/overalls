defmodule Marshall.Compute.TransferPublicKey do
  @moduledoc "Canonical public transfer key storage; private key material is never admissible."
  use Ash.Type

  @impl true
  def storage_type(_), do: :string

  # @cc [owner:ghuntley,label:security] transfer-public-key-storage-only
  # Input, stored and dumped values MUST be nil or the shared canonical Ed25519
  # public key format. Private material and unvalidated strings MUST be rejected.
  @impl true
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(value, _) do
    if OverallsProtocol.TransferSSH.public_key?(value), do: {:ok, value}, else: :error
  end

  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)
  @impl true
  def dump_to_native(value, constraints), do: cast_input(value, constraints)
end
