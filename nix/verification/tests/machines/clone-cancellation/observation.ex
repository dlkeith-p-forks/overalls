defmodule Lilly.CloneObservationFixture do
  @moduledoc false
  import Bitwise
  alias Lilly.Host.{Lock, ZFS}
  @root "/run/clone-zfs-observations"

  # @cc [owner:ghuntley,label:verification;security] clone-exact-observation-context
  # Only the clone fixture may wrap readiness. The callback MUST run exactly once
  # with unchanged arguments/result and exceptions. Context MUST contain only a
  # validated placement UUID and at most eight exact dataset/snapshot GUID bindings,
  # be private and bounded to 4096 bytes, and be removed after the callback. Its
  # filename MUST bind the currently held native pool-lock owner; unlocked calls
  # cannot publish context. Context failure grants no authority and must not retry.
  @spec around(OverallsProtocol.uuid() | nil, ZFS.snapshots(), (-> result)) :: result
        when result: term()
  def around(placement, snapshots, callback) do
    case Lock.current() do
      port when is_port(port) ->
        case Port.info(port, :os_pid) do
          {:os_pid, owner} -> capture(@root, owner, placement, snapshots, callback)
          _ -> callback.()
        end

      _ ->
        callback.()
    end
  end

  @doc false
  @spec capture(
          Path.t(),
          pos_integer(),
          OverallsProtocol.uuid() | nil,
          ZFS.snapshots(),
          (-> result)
        ) ::
          result
        when result: term()
  def capture(root, owner, placement, snapshots, callback) do
    path = Path.join(root, "context-#{owner}.json")

    try do
      if File.regular?(Path.join(root, "armed")) and private_root?(root) do
        # One configured pool per fixture host serializes these contexts. Remove
        # a previous process's interrupted publication before retaining a new one.
        clear_contexts(root)
        publish(path, placement, snapshots)
      end

      callback.()
    after
      File.rm(path)
      File.rm(path <> ".tmp")
    end
  end

  @spec private_root?(Path.t()) :: boolean()
  defp private_root?(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory, mode: mode}} -> band(mode, 0o777) == 0o700
      _ -> false
    end
  end

  @spec clear_contexts(Path.t()) :: :ok
  defp clear_contexts(root) do
    case File.ls(root) do
      {:ok, entries} ->
        for name <- entries, Regex.match?(~r/\Acontext-[0-9]+\.json(?:\.tmp)?\z/, name) do
          File.rm(Path.join(root, name))
        end

      _ ->
        :ok
    end

    :ok
  end

  @spec publish(Path.t(), OverallsProtocol.uuid() | nil, ZFS.snapshots()) :: :ok
  defp publish(path, placement, snapshots) do
    with true <- OverallsProtocol.uuid?(placement),
         true <- is_map(snapshots) and map_size(snapshots) <= 8,
         true <- Enum.all?(snapshots, &valid_snapshot?/1),
         bytes = JSON.encode!(%{placement_id: placement, snapshots: snapshots}),
         true <- byte_size(bytes) <= 4096,
         {:ok, file} <- File.open(path <> ".tmp", [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(path <> ".tmp", 0o600),
             :ok <- IO.binwrite(file, bytes) do
          File.rename(path <> ".tmp", path)
        end
      after
        File.close(file)
      end
    end

    :ok
  end

  @spec valid_snapshot?({String.t(), map()}) :: boolean()
  defp valid_snapshot?({name, %{dataset_guid: dataset, snapshot_guid: snapshot} = binding})
       when is_binary(name) and map_size(binding) == 2 do
    with ["zroot/lilly/vm-" <> placement, suffix] <- String.split(name, "@"),
         true <- suffix in ["lilly-b", "lilly-backup"] do
      OverallsProtocol.uuid?(placement) and OverallsProtocol.Storage.guid?(dataset) and
        OverallsProtocol.Storage.guid?(snapshot)
    else
      _ -> false
    end
  end

  defp valid_snapshot?(_), do: false
end
