defmodule Overalls.RequestAccounting.QualityMarker do
  @moduledoc "Private fsynced source quality state, independent of metric lifetime."

  @type quality :: :clean | :running | :gap
  @type error :: {:error, :storage}

  @spec read(binary()) :: {:ok, quality() | :new} | error()
  def read(directory) do
    with :ok <- private_directory(directory) do
      path = Path.join(directory, "quality")

      case File.lstat(path) do
        {:error, :enoent} -> {:ok, :new}
        {:ok, stat} -> read_existing(path, stat)
        _ -> {:error, :storage}
      end
    end
  end

  # @cc [owner:ghuntley,label:reliability;security] source-quality-durable-before-use
  # A successful write MUST fsync a private exclusive stage, atomically replace
  # the quality marker and fsync its private directory. Corrupt or foreign-owned
  # state MUST refuse replacement. Failure MUST NOT permit healthy publication.
  @spec write(binary(), quality()) :: :ok | error()
  def write(directory, quality) when quality in [:clean, :running, :gap] do
    with {:ok, _previous} <- read(directory),
         :ok <- clear_interrupted_stage(directory),
         :ok <- staged_write(directory, "v1:" <> Atom.to_string(quality) <> "\n") do
      :ok
    else
      _ -> {:error, :storage}
    end
  end

  @spec private_directory(binary()) :: :ok | error()
  defp private_directory(directory) do
    with {:ok, %File.Stat{type: :directory, mode: mode, uid: uid}} <- File.lstat(directory),
         true <- Bitwise.band(mode, 0o777) == 0o700,
         {:ok, owner} <- owner_uid(),
         true <- uid == owner do
      :ok
    else
      _ -> {:error, :storage}
    end
  end

  @spec owner_uid() :: {:ok, non_neg_integer()} | error()
  defp owner_uid do
    case File.stat("/proc/self") do
      {:ok, %File.Stat{uid: uid}} -> {:ok, uid}
      _ -> {:error, :storage}
    end
  end

  @spec private_file?(File.Stat.t()) :: boolean()
  defp private_file?(%File.Stat{type: :regular, mode: mode, uid: uid, links: 1}) do
    Bitwise.band(mode, 0o777) == 0o600 and owner_uid() == {:ok, uid}
  end

  defp private_file?(_stat), do: false

  @spec read_existing(binary(), File.Stat.t()) :: {:ok, quality()} | error()
  defp read_existing(path, stat) do
    with true <- private_file?(stat),
         true <- stat.size <= 16,
         {:ok, bytes} <- File.read(path) do
      case bytes do
        "v1:clean\n" -> {:ok, :clean}
        "v1:running\n" -> {:ok, :running}
        "v1:gap\n" -> {:ok, :gap}
        _ -> {:error, :storage}
      end
    else
      _ -> {:error, :storage}
    end
  end

  @spec clear_interrupted_stage(binary()) :: :ok | error()
  defp clear_interrupted_stage(directory) do
    stage = Path.join(directory, "quality.new")

    case File.lstat(stage) do
      {:error, :enoent} -> :ok
      {:ok, stat} -> if private_file?(stat), do: File.rm(stage), else: {:error, :storage}
      _ -> {:error, :storage}
    end
  end

  @spec staged_write(binary(), binary()) :: :ok | error()
  defp staged_write(directory, bytes) do
    stage = Path.join(directory, "quality.new")

    case :file.open(String.to_charlist(stage), [:write, :raw, :binary, :exclusive]) do
      {:ok, fd} ->
        result =
          with :ok <- File.chmod(stage, 0o600),
               :ok <- :file.write(fd, bytes),
               :ok <- :file.sync(fd) do
            :ok
          end

        closed = :file.close(fd)

        with :ok <- result,
             :ok <- closed,
             :ok <- File.rename(stage, Path.join(directory, "quality")),
             :ok <- sync_directory(directory) do
          :ok
        else
          _ -> {:error, :storage}
        end

      _ ->
        {:error, :storage}
    end
  end

  @spec sync_directory(binary()) :: :ok | error()
  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
      {:ok, fd} ->
        result = :file.sync(fd)
        closed = :file.close(fd)
        if result == :ok and closed == :ok, do: :ok, else: {:error, :storage}

      _ ->
        {:error, :storage}
    end
  end
end
