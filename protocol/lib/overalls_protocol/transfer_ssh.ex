defmodule OverallsProtocol.TransferSSH do
  @moduledoc "Closed operator-enrolled SSH endpoint identity; no discovery or trust-on-first-use."
  @type endpoint :: %{String.t() => String.t() | pos_integer()}

  # @cc [owner:ghuntley,label:security] transfer-endpoint-explicit-host-key
  # endpoint/1 MUST accept only an exact address/port/Ed25519 public-key record.
  # Addresses MUST be canonical IPv4 literals or bounded lowercase DNS names without
  # SSH options, user names, wildcard patterns, zone identifiers or control bytes.
  # Parsing MUST NOT resolve DNS, discover keys, create atoms or establish readiness.
  @spec endpoint(term()) :: {:ok, endpoint()} | {:error, :invalid_transfer_endpoint}
  def endpoint(%{"address" => address, "port" => port, "host_key" => key} = value)
      when map_size(value) == 3 and is_integer(port) and port in 1..65_535 do
    if address?(address) and public_key?(key),
      do: {:ok, value},
      else: {:error, :invalid_transfer_endpoint}
  end

  def endpoint(_), do: {:error, :invalid_transfer_endpoint}

  # @cc [owner:ghuntley,label:security] transfer-ed25519-canonical-public-blob
  # Public keys MUST be canonical single-line ssh-ed25519 values containing exactly
  # the SSH algorithm string and a 32-byte key. Comments, options, trailing bytes,
  # certificates and alternative algorithms MUST fail closed.
  @spec public_key?(term()) :: boolean()
  def public_key?("ssh-ed25519 " <> encoded) when byte_size(encoded) == 68 do
    case Base.decode64(encoded) do
      {:ok, <<11::32, "ssh-ed25519", 32::32, _key::binary-size(32)>> = blob} ->
        Base.encode64(blob) == encoded

      _ ->
        false
    end
  end

  def public_key?(_), do: false

  defp address?(value) when is_binary(value) and byte_size(value) in 1..253 do
    if String.valid?(value) and String.printable?(value) do
      case :inet.parse_ipv4strict_address(String.to_charlist(value)) do
        {:ok, address} -> List.to_string(:inet.ntoa(address)) == value
        {:error, _} -> dns?(value)
      end
    else
      false
    end
  end

  defp address?(_), do: false

  defp dns?(value) do
    # Numeric-looking noncanonical IPv4 must not become a DNS alternative.
    not Regex.match?(~r/\A[0-9.]+\z/, value) and
      Enum.all?(String.split(value, "."), fn label ->
        byte_size(label) in 1..63 and
          Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, label)
      end)
  end
end
