defmodule Lilly.Host.EmptyDirectory do
  @moduledoc false
  alias Lilly.Host.Command

  # @cc [owner:ghuntley,label:security;recovery] empty-mountpoint-removal
  # Callers MUST hold the pool mutation lock and prove dataset/mount absence and
  # canonical parent ownership before remove/2. Removal MUST be nonrecursive,
  # reject non-root directories and other file types, and sync the parent even
  # when already absent. Any removal or sync failure MUST prevent success.
  # Injectable stat/sync functions are for unprivileged filesystem verification.
  @spec remove(Path.t(), keyword()) :: :ok | {:error, atom()}
  def remove(path, opts \\ []) do
    stat = Keyword.get(opts, :stat, &File.lstat/1)
    sync = Keyword.get(opts, :sync, &sync_parent/1)

    with :ok <- remove_directory(path, stat),
         :ok <- sync.(Path.dirname(path)),
         do: :ok
  end

  defp remove_directory(path, stat) do
    case stat.(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :directory, uid: 0}} -> File.rmdir(path)
      {:ok, _} -> {:error, :unsafe_cleanup_directory}
      {:error, _} = error -> error
    end
  end

  defp sync_parent(path) do
    case Command.run(:sync, ["--", path]) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end
end
