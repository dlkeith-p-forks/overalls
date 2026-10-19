defmodule Susan.Credentials do
  @moduledoc """
  Reads operator-owned files with the custody checks used by Porsche
  (`porsche/lib/porsche/config.ex`): canonical absolute paths, trusted
  non-symlink ancestors, single-link regular files owned by this service and
  bounded sizes. Secrets additionally require mode 0400 or 0600 when owned by
  the service, or mode 0400 or 0440 with owner and group root, which is how
  systemd publishes `LoadCredential=` files on tmpfs (it grants the service
  user read access through an ACL).

  Errors are the fixed atom `:error`; file contents, paths and parser
  exceptions never leave this module.
  """
  import Bitwise

  @type kind :: :secret | :config

  # @cc [owner:ghuntley,label:security] susan-credential-file-custody
  # Secrets MUST be read only from canonical paths under trusted non-symlink
  # ancestors, as single-link regular files with a bounded size, either owned
  # by the service user with mode 0400/0600 or root:root read-only 0400/0440
  # (systemd credentials). Nothing else may be able to write them. Failures MUST be the fixed value
  # :error, without contents, paths or exception text.
  @spec read(term(), kind(), pos_integer()) :: {:ok, binary()} | :error
  def read(path, kind, maximum) when kind in [:secret, :config] and is_integer(maximum) do
    with true <- canonical_path?(path),
         :ok <- parents(Path.dirname(path)),
         {:ok, %File.Stat{type: :regular, size: size} = stat} <- File.lstat(path),
         true <- size in 1..maximum and permissions?(stat, kind),
         {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= maximum <-
           File.open(path, [:read, :binary], &IO.binread(&1, maximum + 1)) do
      {:ok, bytes}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Reads one secret by name from the systemd credentials directory."
  @spec secret(term(), String.t(), pos_integer()) :: {:ok, binary()} | :error
  def secret(directory, name, maximum) when is_binary(directory) and is_binary(name) do
    if canonical_path?(directory) and Regex.match?(~r/\A[A-Z][A-Z0-9_]{0,63}\z/, name),
      do: read(Path.join(directory, name), :secret, maximum),
      else: :error
  end

  def secret(_directory, _name, _maximum), do: :error

  @doc "Strips one trailing newline, as written by editors and secret tools."
  @spec chomp(binary()) :: binary()
  def chomp(value) when is_binary(value) do
    if String.ends_with?(value, "\n"),
      do: binary_part(value, 0, byte_size(value) - 1),
      else: value
  end

  @spec canonical_path?(term()) :: boolean()
  def canonical_path?(path) when is_binary(path) and byte_size(path) in 1..4096,
    do:
      String.valid?(path) and Path.type(path) == :absolute and Path.expand(path) == path and
        not String.contains?(path, [<<0>>, "\n", "\r"])

  def canonical_path?(_), do: false

  defp permissions?(%File.Stat{links: 1} = stat, :secret) do
    mode = band(stat.mode, 0o777)

    cond do
      stat.uid == uid() -> mode in [0o400, 0o600]
      stat.uid == 0 and stat.gid == 0 -> mode in [0o400, 0o440]
      true -> false
    end
  end

  defp permissions?(_stat, :secret), do: false

  defp permissions?(stat, :config),
    do: stat.uid in [0, uid()] and band(stat.mode, 0o022) == 0

  defp parents("/"), do: :ok

  defp parents(path) do
    with {:ok, %File.Stat{type: :directory, uid: owner, mode: mode}} <- File.lstat(path),
         true <- owner in [0, uid()],
         true <- band(mode, 0o022) == 0 or band(mode, 0o1000) != 0 do
      parents(Path.dirname(path))
    else
      _ -> :error
    end
  end

  defp uid do
    {:ok, stat} = File.stat("/proc/self")
    stat.uid
  end
end
