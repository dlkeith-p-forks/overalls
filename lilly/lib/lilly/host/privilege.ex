defmodule Lilly.Host.Privilege do
  @moduledoc """
  The service identity Lilly's ownership checks trust (ADR-0182).

  Lilly state is written either by lilly-hostd (as root) or by the BEAM
  itself, which always runs as the configured service user; root tools
  (backups, transfer workers, test probes) set the same uid so they trust
  what the service wrote. `lstat/2` and `stat/1` report a
  file owned by the configured service uid as uid 0, so ownership patterns
  that require `uid: 0` accept exactly "root or the service user", and the
  root gates (`stat("/proc/self")` with uid 0) admit exactly a BEAM running
  as root or as that user. The service uid comes from `LILLY_SERVICE_UID`;
  without it it is 0 and nothing changes.

  System files whose root ownership matters on its own (`/etc`, the Nix
  store, configured images) keep plain `File.lstat/1`.
  """

  @key {__MODULE__, :service_uid}

  # @cc [owner:ghuntley,label:security] service-uid-normalised-to-root
  # lstat/2 and stat/1 MUST return File's result unchanged except that a uid
  # equal to the configured service uid (LILLY_SERVICE_UID, default 0) is
  # reported as 0. No other uid, in particular no guest (jail) uid or the
  # uid of an unconfigured non-root BEAM, may be reported as 0, so the root
  # gates still fail closed for any other user.
  @spec lstat(Path.t(), keyword()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def lstat(path, options \\ []), do: path |> File.lstat(options) |> normalise()

  @spec stat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def stat(path), do: path |> File.stat() |> normalise()

  @doc "The configured service uid (LILLY_SERVICE_UID), read once; 0 when unset."
  @spec service_uid() :: non_neg_integer()
  def service_uid do
    case :persistent_term.get(@key, nil) do
      nil ->
        uid =
          case Integer.parse(System.get_env("LILLY_SERVICE_UID", "0")) do
            {value, ""} when value >= 0 -> value
            _ -> 0
          end

        :persistent_term.put(@key, uid)
        uid

      uid ->
        uid
    end
  end

  # @cc [owner:ghuntley,label:security] chmod-through-hostd-when-not-owner
  # chmod/2 MUST set exactly `mode` on `path`. A file the caller does not own
  # (root- or jail-owned) is changed by hostd's closed `chmod` utility under
  # the caller's lease, and only after File.chmod/2 failed with :eperm; no
  # other error falls back.
  @spec chmod(Path.t(), 0..0o7777) :: :ok | {:error, atom()}
  def chmod(path, mode) do
    case File.chmod(path, mode) do
      {:error, :eperm} ->
        octal = Integer.to_string(mode, 8)

        case Lilly.Host.Command.run(:chmod, [octal, "--", path]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      result ->
        result
    end
  end

  # @cc [owner:ghuntley,label:security] remove-tree-through-hostd-when-not-owner
  # remove_tree/1 MUST remove `path` recursively without crossing a file
  # system. When File.rm_rf/1 could not remove everything (entries the jailer
  # created as root or a jail uid), hostd's `rm -rf --one-file-system`
  # finishes it under the caller's lease. Success means the path no longer
  # exists.
  @spec remove_tree(Path.t()) :: :ok | {:error, atom()}
  def remove_tree(path) do
    case File.rm_rf(path) do
      {:ok, _} ->
        :ok

      {:error, _, _} ->
        with {:ok, _} <-
               Lilly.Host.Command.run(:rm, ["-rf", "--one-file-system", "--", path]),
             {:error, :enoent} <- File.lstat(path) do
          :ok
        else
          {:error, reason} when is_atom(reason) -> {:error, reason}
          _ -> {:error, :remove_unconfirmed}
        end
    end
  end

  # @cc [owner:ghuntley,label:security] claimed-directory-owned-by-service
  # claim_directory/1 MUST leave a dataset or template root that hostd
  # created (root-owned) as a 0700 directory owned by the service uid, so the
  # BEAM can write its metadata there; the chown to the service uid runs
  # through hostd under the caller's lease. With no configured service uid
  # (a root tool without LILLY_SERVICE_UID) it is chmod 0700 only.
  @spec claim_directory(Path.t()) :: :ok | {:error, atom()}
  def claim_directory(path) do
    uid = service_uid()

    with :ok <- claim_owner(path, uid),
         do: File.chmod(path, 0o700)
  end

  defp claim_owner(_path, 0), do: :ok

  defp claim_owner(path, uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, uid: ^uid}} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        case Lilly.Host.Command.run(:chown, ["#{uid}:#{uid}", "--", path]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, _} ->
        {:error, :not_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalise({:ok, %File.Stat{uid: uid} = stat}) do
    if uid != 0 and uid == service_uid(), do: {:ok, %{stat | uid: 0}}, else: {:ok, stat}
  end

  defp normalise(error), do: error
end
