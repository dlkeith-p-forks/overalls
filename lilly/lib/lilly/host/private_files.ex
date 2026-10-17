defmodule Lilly.Host.PrivateFiles do
  @moduledoc "Private local state with file-data and directory durability before acknowledgement."
  import Bitwise
  alias Lilly.Host.Command

  @spec directory(Path.t()) :: :ok | {:error, atom()}
  def directory(path) do
    with true <- Path.type(path) == :absolute and Path.expand(path) == path,
         :ok <- safe_parents(Path.dirname(path)),
         :ok <- create_directory(path),
         {:ok, %File.Stat{type: :directory, mode: mode, uid: uid}} <- File.lstat(path),
         true <- band(mode, 0o777) == 0o700 and uid == uid() do
      :ok
    else
      _ -> {:error, :unsafe_state_directory}
    end
  end

  # @cc [owner:ghuntley,label:security] private-single-link-secrets
  # read_secret/1 MUST reject symlinks, non-regular or multiply linked files, files over 65536
  # bytes, wrong owners, permissions other than 0600, and unsafe parent directories before
  # returning secret or durable-state bytes.
  @spec read_secret(Path.t()) :: {:ok, binary()} | {:error, atom()}
  def read_secret(path) do
    with {:ok, %File.Stat{type: :regular, mode: mode, uid: owner, links: 1, size: size}} <-
           File.lstat(path),
         true <- band(mode, 0o777) == 0o600 and owner == uid() and size <= 65_536,
         :ok <- safe_parents(Path.dirname(Path.expand(path))),
         {:ok, contents} <- File.read(path) do
      {:ok, contents}
    else
      _ -> {:error, :unsafe_credential_file}
    end
  end

  # @cc [owner:ghuntley,label:recovery] state-publication-durable-before-success
  # write/3 MUST return :ok only after private file contents are synced, atomically published and
  # the containing directory is synced. A write error is an uncertain publication outcome, not
  # proof the prior file remains unchanged.
  @spec write(Path.t(), String.t(), binary()) :: :ok | {:error, atom()}
  def write(directory, name, contents) do
    with :ok <- directory(directory),
         true <- Regex.match?(~r/\A[a-zA-Z0-9_.-]{1,128}\z/, name) and name not in [".", ".."] do
      suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
      temporary = Path.join(directory, ".pending-" <> suffix)
      destination = Path.join(directory, name)

      try do
        with {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary]),
             :ok <- write_and_sync(file, temporary, contents),
             :ok <- publish(temporary, destination),
             {:ok, _} <- Command.run(:sync, ["--", directory]) do
          :ok
        else
          _ -> {:error, :state_write_failed}
        end
      after
        File.rm(temporary)
      end
    else
      _ -> {:error, :unsafe_state_directory}
    end
  end

  defp write_and_sync(file, path, contents) do
    try do
      with :ok <- File.chmod(path, 0o600),
           :ok <- IO.binwrite(file, contents),
           do: :file.sync(file)
    after
      File.close(file)
    end
  end

  defp create_directory(path) do
    case File.mkdir(path) do
      :ok -> File.chmod(path, 0o700)
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  defp publish(source, destination) do
    if Lilly.Host.Lock.current() do
      # Publish through the lock-owning child, so an accepted rename cannot
      # outlive the lock when its BEAM caller dies. Both paths share a directory.
      with {:ok, _} <- Command.run(:mv, ["--no-target-directory", "--", source, destination]),
           do: :ok
    else
      File.rename(source, destination)
    end
  end

  defp safe_parents("/"), do: :ok

  defp safe_parents(path) do
    with {:ok, %File.Stat{type: :directory, mode: mode, uid: owner}} <- File.lstat(path),
         true <- owner in [0, uid()],
         true <- band(mode, 0o022) == 0 or band(mode, 0o1000) != 0,
         do: safe_parents(Path.dirname(path))
  end

  defp uid do
    {:ok, stat} = File.stat("/proc/self")
    stat.uid
  end
end
