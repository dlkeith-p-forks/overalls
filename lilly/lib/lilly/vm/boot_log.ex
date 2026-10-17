defmodule Lilly.VM.BootLog do
  @moduledoc "Bounded host boot diagnostics, independent of guest readiness or terminal authority."
  import Bitwise
  alias Lilly.Host.PrivateFiles
  alias Lilly.VM.{Boot, Intent}

  @chunk 16_384
  @maximum 9_223_372_036_854_775_807
  @type page :: %{next: non_neg_integer(), bytes: binary()}
  @type revision :: {pos_integer(), pos_integer()}
  @type running_probe :: (-> boolean())
  @type snapshot :: %{
          boot: Boot.t(),
          intent: Intent.t(),
          attempted_generation: pos_integer()
        }

  # @cc [owner:ghuntley,label:security;recovery] boot-log-current-incarnation
  # Reads MUST return at most 16384 bytes from a private, single-link regular
  # inode for an unchanged exact placement/epoch/generation boot and intent.
  # An exact launch-attempt receipt proves the previous log was removed before
  # launch. An older same-epoch attempt MAY be accepted only for running intent
  # with a fully verified confined VMM before and after the read. Metadata
  # snapshots, an older attempt alone, or guest readiness MUST NOT substitute
  # for this incarnation proof. No path, boot challenge or guest dial authority
  # may leave this diagnostic interface.
  @spec read(Path.t(), OverallsProtocol.uuid(), revision(), non_neg_integer(), running_probe()) ::
          {:ok, page()} | {:error, :boot_log_unavailable}
  def read(directory, placement, revision, cursor, running? \\ fn -> false end)

  def read(directory, placement, revision, cursor, running?)
      when is_integer(cursor) and cursor >= 0 and cursor <= @maximum do
    with {:ok, snapshot} <- snapshot(directory, placement, revision),
         true <- incarnation?(snapshot, running?),
         {:ok, before} <- private_log(directory),
         {:ok, page} <- read_inode(directory, before, cursor),
         true <- incarnation?(snapshot, running?),
         {:ok, ^snapshot} <- snapshot(directory, placement, revision),
         {:ok, published} <- private_log(directory),
         true <- same_inode?(before, published) do
      {:ok, page}
    else
      _ -> {:error, :boot_log_unavailable}
    end
  end

  def read(_, _, _, _, _), do: {:error, :boot_log_unavailable}

  @spec snapshot(Path.t(), OverallsProtocol.uuid(), revision()) ::
          {:ok, snapshot()} | {:error, :boot_log_unavailable}
  defp snapshot(directory, placement, {epoch, generation}) do
    with {:ok,
          %{placement_id: ^placement, execution_epoch: ^epoch, generation: ^generation} = boot} <-
           Boot.read(directory),
         {:ok,
          %{placement_id: ^placement, execution_epoch: ^epoch, generation: ^generation} = intent} <-
           Intent.read(directory),
         true <- intent.state in [:running, :failed],
         {:ok,
          <<^placement::binary-size(36), ^epoch::unsigned-big-64, attempted::unsigned-big-64>>} <-
           PrivateFiles.read_secret(Path.join(directory, "launch-attempt.bin")),
         true <- attempted > 0 and attempted <= generation do
      {:ok, %{boot: boot, intent: intent, attempted_generation: attempted}}
    else
      _ -> {:error, :boot_log_unavailable}
    end
  end

  @spec incarnation?(snapshot(), running_probe()) :: boolean()
  defp incarnation?(%{boot: %{generation: generation}, attempted_generation: generation}, _),
    do: true

  defp incarnation?(%{intent: %{state: :running}}, running?), do: running?.()
  defp incarnation?(_, _), do: false

  @spec private_log(Path.t()) :: {:ok, File.Stat.t()} | {:error, :boot_log_unavailable}
  defp private_log(directory) do
    with {:ok, %File.Stat{type: :directory, mode: mode, uid: owner}} <- File.lstat(directory),
         true <- band(mode, 0o777) == 0o700,
         {:ok, %File.Stat{type: :regular, links: 1, mode: mode, uid: ^owner} = stat} <-
           File.lstat(Path.join(directory, "boot.log")),
         true <- band(mode, 0o777) == 0o600 do
      {:ok, stat}
    else
      _ -> {:error, :boot_log_unavailable}
    end
  end

  @spec read_inode(Path.t(), File.Stat.t(), non_neg_integer()) ::
          {:ok, page()} | {:error, :boot_log_unavailable}
  defp read_inode(directory, before, cursor) do
    case File.open(Path.join(directory, "boot.log"), [:read, :raw, :binary]) do
      {:ok, file} ->
        try do
          with {:ok, opened} <- descriptor_stat(file),
               true <- same_inode?(before, opened),
               {:ok, page} <- page(file, cursor, opened.size),
               {:ok, after_read} <- descriptor_stat(file),
               {:ok, published} <- private_log(directory),
               true <- same_inode?(opened, after_read) and same_inode?(opened, published) do
            {:ok, page}
          else
            _ -> {:error, :boot_log_unavailable}
          end
        after
          File.close(file)
        end

      _ ->
        {:error, :boot_log_unavailable}
    end
  end

  @spec descriptor_stat(:file.io_device()) :: {:ok, File.Stat.t()} | {:error, atom()}
  defp descriptor_stat(file) do
    case :file.read_file_info(file) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec same_inode?(File.Stat.t(), File.Stat.t()) :: boolean()
  defp same_inode?(left, right) do
    Enum.all?([:inode, :major_device, :minor_device, :uid, :mode, :links, :type], fn field ->
      Map.fetch!(left, field) == Map.fetch!(right, field)
    end)
  end

  @spec page(:file.io_device(), non_neg_integer(), non_neg_integer()) ::
          {:ok, page()} | {:error, atom()}
  defp page(_, cursor, size) when size <= cursor,
    do: {:ok, %{next: min(cursor, size), bytes: ""}}

  defp page(file, cursor, size) do
    case :file.pread(file, cursor, min(size - cursor, @chunk)) do
      {:ok, bytes} -> {:ok, %{next: cursor + byte_size(bytes), bytes: bytes}}
      _ -> {:error, :boot_log_unavailable}
    end
  end
end
