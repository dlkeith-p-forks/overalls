defmodule Susan.Deployment do
  @moduledoc """
  A Marshall deployment identity: the lower-case DNS management host, with an
  optional port, exactly as it appears in `overalls://HOST[:PORT]/...` app
  routes (ADR-0221). Push keys bind it at issuance and pokes must repeat it.
  """

  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value) and byte_size(value) in 1..259 do
    case String.split(value, ":") do
      [host] ->
        OverallsProtocol.SSHHostCertificate.hostname?(host) and String.contains?(host, ".")

      [host, port] ->
        OverallsProtocol.SSHHostCertificate.hostname?(host) and String.contains?(host, ".") and
          Regex.match?(~r/\A[1-9][0-9]{0,4}\z/, port) and String.to_integer(port) <= 65_535

      _ ->
        false
    end
  end

  def valid?(_), do: false
end
