defmodule Lilly.Lifecycle.BackupHistory do
  @moduledoc "Terminal per-run audit history, independent of control-plane availability."
  alias Lilly.Host.{Command, Lock, PrivateFiles}
  alias Lilly.Lifecycle.{BackupSnapshot, Journal}
  @retention_us 90 * 86_400 * 1_000_000
  @type failure :: {:error, :backup_history_unconfirmed}

  # @cc [owner:ghuntley,label:recovery;durability] backup-history-after-physical-cleanup
  # The caller MUST hold the pool lock and prove the previous snapshot absent
  # before prepare/2. Only the exact expected cleaned journal may be archived.
  # Move the original envelope without changing producer/event identities, under
  # the native lock owner, and sync its directory before permitting a new run.
  # Never replace an existing history file or archive active/corrupt metadata.
  # A crash after archival but before initialization leaves no active snapshot;
  # a new producer may initialize while the old events remain independently due.
  @spec prepare(Path.t(), map() | nil) :: :ok | failure()
  def prepare(directory, expected) do
    with :ok <- owned(),
         :ok <- PrivateFiles.directory(directory),
         :ok <- expire(directory),
         {:ok, record} <- Journal.load(BackupSnapshot, directory, "backup.json"),
         do: archive(directory, record, expected),
         else: (_ -> failure())
  end

  defp archive(_, nil, nil), do: :ok

  defp archive(directory, %{state: :cleaned, payload: expected} = record, expected) do
    timestamp =
      System.system_time(:microsecond) |> Integer.to_string() |> String.pad_leading(20, "0")

    name = "backup-" <> timestamp <> "-" <> record.id <> ".json"
    source = Path.join(directory, "backup.json")
    destination = Path.join(directory, name)

    with {:error, :enoent} <- File.lstat(destination),
         {:ok, _} <-
           Command.run(:mv, ["--no-clobber", "--no-target-directory", "--", source, destination]),
         {:error, :enoent} <- File.lstat(source),
         {:ok, archived} <- Journal.load(BackupSnapshot, directory, name),
         true <-
           archived.id == record.id and archived.revision == record.revision and
             archived.payload == expected,
         {:ok, _} <- Command.run(:sync, ["--", directory]),
         do: :ok,
         else: (_ -> failure())
  end

  defp archive(_, _, _), do: failure()

  # @cc [owner:ghuntley,label:retention;security] backup-history-expiry-is-audit-only
  # With the pool lock, expire/2 may inspect/remove at most sixteen oldest named
  # archives older than ninety days. Require a private valid cleaned envelope
  # whose producer ID matches its archive name. Retain corrupt, mismatched,
  # active and unexpired files; never select backup.json or native evidence.
  # Only state-only v2 envelopes are valid history.
  # No Marshall connection is required. Enumeration is proportional to retained history.
  @spec expire(Path.t(), pos_integer()) :: :ok | failure()
  def expire(directory, now \\ System.system_time(:microsecond))
      when is_integer(now) and now > 0 do
    with :ok <- owned(), {:ok, names} <- File.ls(directory) do
      names
      |> Enum.flat_map(fn name ->
        case identity(name) do
          {:ok, timestamp, id} when timestamp < now - @retention_us -> [{name, id}]
          _ -> []
        end
      end)
      |> Enum.sort()
      |> Enum.take(16)
      |> Enum.reduce_while(:ok, fn {name, id}, :ok ->
        case Journal.load(BackupSnapshot, directory, name) do
          {:ok, %{id: ^id, state: :cleaned}} ->
            case Command.run(:rm, ["--", Path.join(directory, name)]) do
              {:ok, _} -> {:cont, :ok}
              _ -> {:halt, failure()}
            end

          _ ->
            {:cont, :ok}
        end
      end)
      |> case do
        :ok ->
          case Command.run(:sync, ["--", directory]) do
            {:ok, _} -> :ok
            _ -> failure()
          end

        error ->
          error
      end
    else
      _ -> failure()
    end
  end

  @spec exportable?(String.t()) :: boolean()
  def exportable?(name) do
    case identity(name) do
      {:ok, timestamp, _} -> timestamp >= System.system_time(:microsecond) - @retention_us
      _ -> false
    end
  end

  defp identity("backup-" <> <<timestamp::binary-size(20), "-", id::binary-size(36), ".json">>) do
    with true <- Regex.match?(~r/\A[0-9]{20}\z/, timestamp),
         {time, ""} when time > 0 <- Integer.parse(timestamp),
         true <- OverallsProtocol.uuid?(id),
         do: {:ok, time, id},
         else: (_ -> :error)
  end

  defp identity(_), do: :error

  defp owned do
    case Lock.current() do
      %Lilly.Host.Lease{} = lease -> if Lock.held?(lease), do: :ok, else: failure()
      _ -> failure()
    end
  end

  defp failure, do: {:error, :backup_history_unconfirmed}
end
