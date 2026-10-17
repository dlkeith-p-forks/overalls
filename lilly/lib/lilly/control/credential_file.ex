defmodule Lilly.Control.CredentialFile do
  @moduledoc "Read a Marshall-issued private credential envelope bound to the configured host."

  # @cc [owner:ghuntley,label:security] credential-envelope-host-binding
  # read/2 MUST return a token only from a private canonical file whose exact five-field envelope
  # matches the configured host and token credential ID and contains a valid UTC expiry timestamp.
  # Expiry enforcement remains Marshall authority; malformed contents return only
  # invalid_credential_file.
  @spec read(Path.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_credential_file}
  def read(path, host_id) do
    with true <- is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path,
         {:ok, bytes} <- Lilly.Host.PrivateFiles.read_secret(path),
         {:ok,
          %{
            "version" => 1,
            "host_id" => ^host_id,
            "credential_id" => id,
            "credential" => token,
            "expires_at" => expiry
          } = envelope} <- JSON.decode(bytes),
         true <-
           map_size(envelope) == 5 and OverallsProtocol.uuid?(id) and
             OverallsProtocol.uuid?(host_id),
         true <- is_binary(token) and byte_size(token) == 80,
         [^id, secret] <- String.split(token, ":", parts: 2),
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, secret),
         {:ok, _, 0} <- DateTime.from_iso8601(expiry) do
      {:ok, token}
    else
      _ -> {:error, :invalid_credential_file}
    end
  rescue
    _ -> {:error, :invalid_credential_file}
  end
end
