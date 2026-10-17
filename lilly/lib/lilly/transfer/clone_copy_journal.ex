defmodule Lilly.Transfer.CloneCopyJournal do
  @moduledoc """
  Local same-pool block-copy intent and progress (ADR-0145). The journal binds a
  clone destination to its verified source snapshot and its own ordinary dataset
  claim; it never grants execution authority or capacity credit.
  """
  require Lilly.Events
  alias OverallsProtocol.Storage
  alias OverallsProtocol.DiskTransfer, as: Relocation
  alias Lilly.Host.{Command, Lock, PrivateFiles}

  @filename "copy.json"
  @phases ~w(copying copied adopted retiring retired)
  @type journal :: %{String.t() => term()}
  @type failure :: {:error, :clone_copy_state_unconfirmed}

  @doc "Directory for a placement's copy journal under the pool metadata root."
  @spec directory(Path.t(), String.t()) :: Path.t()
  def directory(pool_path, placement_id),
    do: Path.join([pool_path, ".lilly-zfs", "copies", placement_id])

  # @cc [owner:ghuntley,label:security;recovery] clone-copy-intent-precedes-dataset
  # prepare/3 MUST persist the immutable clone binding and source snapshot GUID
  # before any destination dataset exists. Callers MUST hold the destination pool
  # lock, current clone authority and a same-host, same-pool full-stream descriptor.
  # Retries return the existing record unchanged; a retired record never revives.
  @spec prepare(Path.t(), Relocation.descriptor(), Storage.identity()) ::
          {:ok, journal()} | failure()
  def prepare(directory, descriptor, identity) do
    mutate(directory, descriptor, identity, true, fn record ->
      if record["phase"] in ["copying", "copied", "adopted"],
        do: {:ok, record},
        else: :error
    end)
  end

  # @cc [owner:ghuntley,label:security] clone-copy-claim-bound-once
  # bind/5 MUST bind the destination's own ordinary claim nonce and dataset GUID at
  # most once while copying. Callers MUST verify the claim file, native lilly:nonce
  # and GUID agree under the pool lock. The source GUID is never ownership proof.
  @spec bind(Path.t(), Relocation.descriptor(), Storage.identity(), String.t(), String.t()) ::
          {:ok, journal()} | failure()
  def bind(directory, descriptor, identity, nonce, guid) do
    mutate(directory, descriptor, identity, false, fn record ->
      if record["phase"] == "copying" and nonce?(nonce) and Storage.guid?(guid) and
           record["nonce"] in [nil, nonce] and record["dataset_guid"] in [nil, guid],
         do: {:ok, %{record | "nonce" => nonce, "dataset_guid" => guid}},
         else: :error
    end)
  end

  # @cc [owner:ghuntley,label:recovery;security] clone-copy-file-identity-recorded
  # file_copied/6 MUST record each materialized file's exact size and its
  # device-independent source identity once; a differing re-record fails. Only a
  # bound copying journal accepts files, and only names from the fixed disk set.
  @spec file_copied(
          Path.t(),
          Relocation.descriptor(),
          Storage.identity(),
          String.t(),
          non_neg_integer(),
          [non_neg_integer()]
        ) :: {:ok, journal()} | failure()
  def file_copied(directory, descriptor, identity, name, size, source_identity) do
    mutate(directory, descriptor, identity, false, fn record ->
      entry = %{"size" => size, "source" => source_identity}

      cond do
        record["phase"] != "copying" or not Storage.guid?(record["dataset_guid"]) -> :error
        not (is_binary(name) and name in disk_files()) -> :error
        not valid_entry?(entry) -> :error
        record["files"][name] in [nil, entry] -> {:ok, put_in(record, ["files", name], entry)}
        true -> :error
      end
    end)
  end

  # @cc [owner:ghuntley,label:recovery] clone-copy-completion-requires-every-file
  # copied/5 MUST match the bound destination GUID and require exactly the expected
  # file set before marking the copy complete. A copied record MUST NOT authorize
  # launch, publication or source pruning; adoption re-verifies independently.
  @spec copied(Path.t(), Relocation.descriptor(), Storage.identity(), String.t(), [String.t()]) ::
          {:ok, journal()} | failure()
  def copied(directory, descriptor, identity, guid, expected_files) do
    mutate(directory, descriptor, identity, false, fn record ->
      cond do
        record["phase"] == "copied" and record["dataset_guid"] == guid ->
          {:ok, record}

        record["phase"] == "copying" and record["dataset_guid"] == guid and
            Enum.sort(Map.keys(record["files"])) == Enum.sort(expected_files) ->
          {:ok, %{record | "phase" => "copied"}}

        true ->
          :error
      end
    end)
  end

  # @cc [owner:ghuntley,label:recovery] clone-copy-adoption-is-final
  # adopted/4 records local publication of a copied destination with the same
  # GUID. Adoption never reverts to copying or copied; only a discard holding
  # cancellation authority may still retire it (clone-copy-retirement-is-permanent).
  @spec adopted(Path.t(), Relocation.descriptor(), Storage.identity(), String.t()) ::
          {:ok, journal()} | failure()
  def adopted(directory, descriptor, identity, guid) do
    mutate(directory, descriptor, identity, false, fn record ->
      if record["phase"] in ["copied", "adopted"] and record["dataset_guid"] == guid,
        do: {:ok, %{record | "phase" => "adopted"}},
        else: :error
    end)
  end

  # @cc [owner:ghuntley,label:recovery] clone-copy-retirement-is-permanent
  # retire/3 MUST fence further copying and adoption before cleanup; deleted/4
  # requires the exact bound GUID (or none if no dataset was ever bound). A
  # locally adopted copy whose clone was cancelled before Marshall published it
  # MUST remain retirable, as an adopted import is (ADR-0145 keeps Marshall's
  # protocol unchanged). No mutation may resurrect a retired copy.
  @spec retire(Path.t(), Relocation.descriptor(), Storage.identity()) ::
          {:ok, journal()} | failure()
  def retire(directory, descriptor, identity) do
    reported(
      mutate(directory, descriptor, identity, false, fn record ->
        case record["phase"] do
          phase when phase in ["copying", "copied", "adopted", "retiring"] ->
            {:ok, %{record | "phase" => "retiring"}}

          "retired" ->
            {:ok, record}

          _ ->
            :error
        end
      end)
    )
  end

  @spec deleted(Path.t(), Relocation.descriptor(), Storage.identity(), String.t() | nil) ::
          {:ok, journal()} | failure()
  def deleted(directory, descriptor, identity, guid) do
    reported(
      mutate(directory, descriptor, identity, false, fn record ->
        if record["phase"] in ["retiring", "retired"] and record["dataset_guid"] == guid,
          do: {:ok, %{record | "phase" => "retired"}},
          else: :error
      end)
    )
  end

  # @cc [owner:ghuntley,label:security;observability] clone-copy-failure-diagnostics-closed
  # A failed retirement or deletion MUST report only the closed reason atom;
  # records, nonces, GUIDs and descriptors MUST NOT be logged.
  defp reported({:ok, _} = ok), do: ok

  defp reported({:error, reason} = error) do
    Lilly.Events.emit("lilly.transfer_effect_failed", reason: reason)
    error
  end

  # @cc [owner:ghuntley,label:security] clone-copy-record-is-local-authority-only
  # read/3 MUST reject unsafe files, unknown fields and any binding or storage
  # identity mismatch. Missing state stays absent and is never reconstructed.
  @spec read(Path.t(), Relocation.descriptor(), Storage.identity()) ::
          {:ok, journal() | nil} | failure()
  def read(directory, descriptor, identity) do
    with true <- valid_input?(descriptor, identity) do
      case File.lstat(Path.join(directory, @filename)) do
        {:error, :enoent} ->
          {:ok, nil}

        {:ok, _} ->
          with {:ok, bytes} <- PrivateFiles.read_secret(Path.join(directory, @filename)),
               {:ok, record} <- Lilly.Lifecycle.Journal.decode(bytes),
               true <- valid_record?(record, descriptor, identity),
               do: {:ok, record},
               else: (_ -> failure())

        _ ->
          failure()
      end
    else
      _ -> failure()
    end
  end

  @doc "Fixed set of files a same-pool copy may materialize."
  @spec disk_files() :: [String.t()]
  def disk_files, do: ~w(rootfs.ext4 data.raw kernel initrd firmware boot-bundle.json)

  defp mutate(directory, descriptor, identity, initialize?, operation) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         {:ok, previous} <- read(directory, descriptor, identity),
         {:ok, record} <- initial(previous, descriptor, identity, initialize?),
         {:ok, updated} <- operation.(record),
         true <- valid_record?(updated, descriptor, identity),
         :ok <- PrivateFiles.directory(Path.dirname(directory)),
         :ok <- PrivateFiles.directory(directory),
         :ok <-
           Lilly.Lifecycle.Journal.write(
             Lilly.Lifecycle.CloneCopy,
             directory,
             @filename,
             updated
           ),
         {:ok, _} <- Command.run(:sync, ["--", Path.dirname(directory)]) do
      {:ok, updated}
    else
      _ -> failure()
    end
  end

  defp initial(record, _, _, _) when is_map(record), do: {:ok, record}

  defp initial(nil, descriptor, identity, true) do
    if descriptor[:purpose] == :clone do
      {:ok,
       %{
         "version" => 1,
         "binding" => binding(descriptor, identity),
         "phase" => "copying",
         "snapshot_guid" => descriptor.stream.to_guid,
         "nonce" => nil,
         "dataset_guid" => nil,
         "files" => %{}
       }}
    else
      :error
    end
  end

  defp initial(_, _, _, _), do: :error

  defp valid_input?(descriptor, identity) when is_map(descriptor) and is_map(identity) do
    map_size(identity) == 4 and Storage.valid_identity?(identity) and
      match?(
        {:ok, ^descriptor},
        descriptor |> Relocation.encode_descriptor() |> Relocation.descriptor()
      )
  rescue
    _ -> false
  end

  defp valid_input?(_, _), do: false

  defp binding(descriptor, identity) do
    descriptor
    |> Relocation.encode_descriptor()
    |> Map.delete("stream")
    |> Map.put("source_dataset_guid", descriptor.stream.source_dataset_guid)
    |> Map.put("local_storage", Storage.encode(identity))
  end

  defp valid_record?(
         %{
           "version" => 1,
           "binding" => bound,
           "phase" => phase,
           "snapshot_guid" => snapshot,
           "nonce" => nonce,
           "dataset_guid" => guid,
           "files" => files
         } = record,
         descriptor,
         identity
       )
       when map_size(record) == 7 and is_map(files) do
    bound == binding(descriptor, identity) and phase in @phases and
      snapshot == descriptor.stream.to_guid and Storage.guid?(snapshot) and
      (is_nil(nonce) or nonce?(nonce)) and (is_nil(guid) or Storage.guid?(guid)) and
      is_nil(nonce) == is_nil(guid) and
      (phase not in ["copied", "adopted"] or Storage.guid?(guid)) and
      Enum.all?(files, fn {name, entry} -> name in disk_files() and valid_entry?(entry) end)
  end

  defp valid_record?(_, _, _), do: false

  defp valid_entry?(%{"size" => size, "source" => source} = entry)
       when map_size(entry) == 2 and is_integer(size) and size >= 0 and is_list(source) do
    length(source) == 10 and Enum.all?(source, &(is_integer(&1) and &1 >= 0))
  end

  defp valid_entry?(_), do: false

  defp nonce?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{32}\z/, value)
  defp failure, do: {:error, :clone_copy_state_unconfirmed}
end
