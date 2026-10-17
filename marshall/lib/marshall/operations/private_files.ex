defmodule Marshall.Operations.PrivateFiles do
  @moduledoc "Bounded operator files on a trusted Linux filesystem; never overwrite credentials."
  import Bitwise

  # @cc [owner:ghuntley,label:security] private-files-reader-boundary
  # On the trusted local filesystem, read MUST require a canonical absolute path
  # through nonsymlink root/current-user-owned parents to an owner-held 0600
  # regular file with one link, and return at most 65536 bytes. Group/world-writable
  # parents require the sticky bit; unsafe files MUST fail without exposing contents.
  @spec read(Path.t()) :: {:ok, binary()} | {:error, atom()}
  def read(path) do
    with true <- canonical?(path),
         :ok <- parents(Path.dirname(path)),
         {:ok, %File.Stat{type: :regular, uid: owner, mode: mode, links: 1, size: size}} <-
           File.lstat(path),
         true <- owner == uid() and band(mode, 0o7777) == 0o600 and size <= 65_536,
         {:ok, file} <- :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      try do
        case :file.read(file, 65_537) do
          {:ok, bytes} when byte_size(bytes) <= 65_536 -> {:ok, bytes}
          _ -> {:error, :unsafe_private_file}
        end
      after
        :file.close(file)
      end
    else
      _ -> {:error, :unsafe_private_file}
    end
  end

  # @cc [owner:ghuntley,label:recovery] private-files-exclusive-output
  # Output MUST be exclusively created in an owner-held 0700 directory and set to
  # 0600 before invoking the callback. Existing paths MUST NOT be overwritten;
  # callback failures MUST retain the destination for uncertain-result inspection.
  @doc "Creates an empty private destination; failed operations deliberately retain it for inspection."
  @spec with_new(Path.t(), (:file.io_device() -> result)) :: result | {:error, atom()}
        when result: term()
  def with_new(path, fun) do
    with true <- canonical?(path),
         :ok <- parents(Path.dirname(path)),
         {:ok, %File.Stat{type: :directory, uid: owner, mode: mode}} <-
           File.lstat(Path.dirname(path)),
         true <- owner == uid() and band(mode, 0o7777) == 0o700 do
      case :file.open(String.to_charlist(path), [:write, :exclusive, :raw, :binary]) do
        {:ok, file} ->
          try do
            with :ok <- File.chmod(path, 0o600), do: fun.(file)
          after
            :file.close(file)
          end

        {:error, :eexist} ->
          {:error, :output_exists}

        _ ->
          {:error, :output_create_failed}
      end
    else
      _ -> {:error, :unsafe_output_path}
    end
  end

  # @cc [owner:ghuntley,label:recovery] private-files-sync-before-success
  # For a bounded payload and descriptor created by with_new, success MUST mean
  # both file contents and the containing directory entry have been synced.
  # A write or either sync failure MUST NOT be reported as success.
  @spec write_sync(:file.io_device(), Path.t(), binary()) :: :ok | {:error, atom()}
  def write_sync(file, path, bytes) when byte_size(bytes) <= 65_536 do
    with :ok <- :file.write(file, bytes),
         :ok <- :file.sync(file),
         {:ok, directory} <-
           :file.open(String.to_charlist(Path.dirname(path)), [:read, :raw, :directory]) do
      try do
        :file.sync(directory)
      after
        :file.close(directory)
      end
    else
      _ -> {:error, :output_write_failed}
    end
  end

  defp canonical?(path),
    do: is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path

  defp parents("/"), do: :ok

  defp parents(path) do
    with {:ok, %File.Stat{type: :directory, uid: owner, mode: mode}} <- File.lstat(path),
         true <- owner in [0, uid()],
         true <- band(mode, 0o022) == 0 or band(mode, 0o1000) != 0,
         do: parents(Path.dirname(path))
  end

  defp uid do
    {:ok, stat} = File.stat("/proc/self")
    stat.uid
  end
end
