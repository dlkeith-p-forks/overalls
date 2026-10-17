defmodule Ziggy.Credential do
  @moduledoc "Read bounded systemd credentials without including their values in errors."
  import Bitwise

  # @cc [owner:ghuntley,label:security] credential-private-runtime-only
  # Credentials MUST be regular private runtime files outside the Nix store.
  # Missing, empty, multiline, world-readable or oversized keys MUST fail with
  # a fixed error; no exception, path or value may escape the reader.
  @spec read(Path.t()) :: {:ok, binary()} | {:error, :invalid_credential}
  def read(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute and Path.expand(path) == path,
         false <- String.starts_with?(path, "/nix/store/"),
         {:ok, %File.Stat{type: :regular, mode: mode, size: size}} <- File.lstat(path),
         true <- band(mode, 0o077) == 0 and size in 1..8192,
         {:ok, bytes} <- File.read(path),
         value = String.trim_trailing(bytes, "\n"),
         true <- byte_size(value) in 1..8192 and Regex.match?(~r/\A[\x21-\x7e]+\z/, value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_credential}
    end
  end

  def read(_), do: {:error, :invalid_credential}
end
