defmodule Lilly.Transfer.ImportJournal do
  @moduledoc "Local receive intent and lineage; received disk data never grants execution authority."
  require Lilly.Events
  alias OverallsProtocol.Storage
  alias OverallsProtocol.DiskTransfer, as: Relocation
  alias Lilly.Host.{Command, Lock, PrivateFiles}
  @filename "import.json"
  @type journal :: %{String.t() => term()}
  @type failure :: {:error, :import_state_unconfirmed}

  # @cc [owner:ghuntley,label:security;recovery] import-intent-precedes-receive
  # prepare/3 MUST persist destination-local intent and nonce before receiving bytes.
  # Callers MUST hold the destination pool lock, verify enrolled identity, current
  # relocation authority and reservation, and prove native absence for new intent.
  # State lives outside portable data. Retries MUST preserve nonce and filesystem
  # GUID and name the same single full stream (ADR-0155); a different stream for
  # the same import is never admissible.
  @spec prepare(Path.t(), Relocation.descriptor(), Storage.identity()) ::
          {:ok, journal()} | failure()
  def prepare(directory, descriptor, identity) do
    mutate(directory, descriptor, identity, true, fn record ->
      if record["phase"] == "active" and record["stream"] == encoded_stream(descriptor),
        do: {:ok, record},
        else: :error
    end)
  end

  # @cc [owner:ghuntley,label:security] import-guid-is-destination-local
  # bind/5 MUST bind the destination filesystem GUID at most once and match its
  # persisted local nonce. Caller MUST verify native local marker, pool identity,
  # receive-only policy and exact path under the pool lock. Binding during retirement
  # is allowed solely to recover interrupted receive for cleanup, never to resume it.
  # Source filesystem GUID equality MUST NOT be required or used as ownership proof.
  @spec bind(Path.t(), Relocation.descriptor(), Storage.identity(), String.t(), String.t()) ::
          {:ok, journal()} | failure()
  def bind(directory, descriptor, identity, nonce, guid) do
    mutate(directory, descriptor, identity, false, fn record ->
      if record["phase"] in ["active", "retiring"] and record["nonce"] == nonce and
           Storage.guid?(guid) and record["dataset_guid"] in [nil, guid],
         do: {:ok, %{record | "dataset_guid" => guid}},
         else: :error
    end)
  end

  # @cc [owner:ghuntley,label:recovery] import-completion-requires-native-lineage
  # received/5 MUST match the exact current stream, bound local GUID and target
  # snapshot GUID. Caller MUST first prove stream quiescence, no resume token,
  # exact completed native snapshot lineage and unmounted read-only staging policy.
  # A lost process acknowledgement may recover only from that complete native state.
  # A receipt MUST NOT authorize mounting, guest startup, handoff or source deletion.
  @spec received(Path.t(), Relocation.descriptor(), Storage.identity(), String.t(), String.t()) ::
          {:ok, journal()} | failure()
  def received(directory, descriptor, identity, guid, snapshot_guid) do
    mutate(directory, descriptor, identity, false, fn record ->
      if record["phase"] == "active" and record["stream"] == encoded_stream(descriptor) and
           Storage.guid?(guid) and record["dataset_guid"] == guid and
           snapshot_guid == record["stream"]["to_guid"] do
        {:ok, %{record | "stream_state" => "received"}}
      else
        :error
      end
    end)
  end

  # @cc [owner:ghuntley,label:recovery] import-retirement-is-permanent
  # retire/3 MUST fence new receive intent and completion before cleanup. It does
  # not terminate active streams: caller MUST revoke/reap them before destroying
  # storage. deleted/4 requires proven native absence and the exact bound GUID,
  # retaining a permanent tombstone. No mutation may resurrect a retired import.
  @spec retire(Path.t(), Relocation.descriptor(), Storage.identity()) ::
          {:ok, journal()} | failure()
  def retire(directory, descriptor, identity) do
    reported(
      mutate(directory, descriptor, identity, true, fn record ->
        {:ok,
         %{record | "phase" => if(record["phase"] == "retired", do: "retired", else: "retiring")}}
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

  # @cc [owner:ghuntley,label:security;observability] import-journal-failure-diagnostics-closed
  # A failed durable import-journal mutation MUST report only the closed
  # journal reason atom; records, nonces, GUIDs and descriptor payloads MUST
  # NOT be logged. Owning retry loops keep their own deduplicated diagnostics,
  # so repeated failures here are bounded by the caller's lease.
  defp reported({:ok, _} = ok), do: ok

  defp reported({:error, reason} = error) do
    Lilly.Events.emit("lilly.transfer_effect_failed", reason: reason)
    error
  end

  # @cc [owner:ghuntley,label:security] import-record-is-local-authority-only
  # read/3 MUST reject unsafe files, unknown fields and any immutable endpoint,
  # workload, epoch, source filesystem or local pool identity mismatch. Missing
  # state remains absent; received stream properties MUST NOT reconstruct it.
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

  # @cc [owner:ghuntley,label:security;recovery] local-import-inventory-is-not-effect-authority
  # local/2 requires the pool lock and MUST validate the private journal against
  # the configured native storage identity before returning its descriptor.
  # Callers MUST separately match destination host/pool/placement and native
  # ownership. Inventory may defer readiness, never authorize an effect or credit.
  @spec local(Path.t(), Storage.identity()) ::
          {:ok, %{descriptor: Relocation.descriptor(), journal: journal()}} | failure()
  def local(directory, identity) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         true <- Storage.valid_identity?(identity),
         {:ok, bytes} <- PrivateFiles.read_secret(Path.join(directory, @filename)),
         {:ok, %{"binding" => bound, "stream" => stream} = record} <-
           Lilly.Lifecycle.Journal.decode(bytes),
         true <- is_map(bound),
         {:ok, descriptor} <-
           bound
           |> Map.drop(["local_storage", "source_dataset_guid"])
           |> Map.put("stream", stream)
           |> Relocation.descriptor(),
         true <- valid_record?(record, descriptor, identity) do
      {:ok, %{descriptor: descriptor, journal: record}}
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] import-history-bound-to-cancellation-intent
  # for_intent/3 requires the destination pool lock. It MUST recover lineage only
  # from the private local journal and match every immutable intent field and the
  # configured storage identity. Missing history remains nil; malformed, unsafe or
  # mismatched history MUST fail without mutation or invented GUIDs. This lookup
  # grants neither cleanup nor execution authority: callers must independently
  # fence transfer/launch work and prove physical quiescence before reclamation.
  @spec for_intent(Path.t(), Relocation.intent(), Storage.identity()) ::
          {:ok, %{descriptor: Relocation.descriptor(), journal: journal()} | nil} | failure()
  def for_intent(directory, intent, identity) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         true <- is_map(identity) and map_size(identity) == 4,
         true <- Storage.valid_identity?(identity),
         {:ok, encoded} <- wire(intent, 0),
         true <- is_map(encoded),
         {:ok, ^intent} <- Relocation.intent(Map.put(encoded, "version", 3)) do
      case File.lstat(Path.join(directory, @filename)) do
        {:error, :enoent} ->
          {:ok, nil}

        {:ok, _} ->
          with {:ok, bytes} <- PrivateFiles.read_secret(Path.join(directory, @filename)),
               {:ok, %{"binding" => bound, "stream" => stream} = record} <-
                 Lilly.Lifecycle.Journal.decode(bytes),
               true <- is_map(bound),
               {:ok, descriptor} <-
                 bound
                 |> Map.drop(["local_storage", "source_dataset_guid"])
                 |> Map.put("stream", stream)
                 |> Relocation.descriptor(),
               true <- Map.delete(descriptor, :stream) == intent,
               true <- valid_record?(record, descriptor, identity),
               do: {:ok, %{descriptor: descriptor, journal: record}},
               else: (_ -> failure())

        _ ->
          failure()
      end
    else
      _ -> failure()
    end
  end

  defp mutate(directory, descriptor, identity, initialize?, operation) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         {:ok, previous} <- read(directory, descriptor, identity),
         {:ok, record} <- initial(directory, previous, descriptor, identity, initialize?),
         {:ok, updated} <- operation.(record),
         true <- valid_record?(updated, descriptor, identity),
         :ok <-
           Lilly.Lifecycle.Journal.write(Lilly.Lifecycle.Import, directory, @filename, updated),
         {:ok, _} <- Command.run(:sync, ["--", Path.dirname(directory)]) do
      {:ok, updated}
    else
      _ -> failure()
    end
  end

  defp initial(_, record, _, _, _) when is_map(record), do: {:ok, record}

  defp initial(directory, nil, descriptor, identity, true) do
    if empty?(directory) do
      {:ok,
       %{
         "version" => 1,
         "binding" => binding(descriptor, identity),
         "phase" => "active",
         "nonce" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
         "dataset_guid" => nil,
         "stream" => encoded_stream(descriptor),
         "stream_state" => "receiving"
       }}
    else
      :error
    end
  end

  defp initial(_, _, _, _, _), do: :error

  defp empty?(directory) do
    case File.ls(directory) do
      {:error, :enoent} ->
        true

      {:ok, names} ->
        Enum.all?(names, fn name ->
          name == "owner.lock" or
            (Regex.match?(~r/\A\.pending-[A-Za-z0-9_-]{16}\z/, name) and
               match?({:ok, _}, PrivateFiles.read_secret(Path.join(directory, name))))
        end)

      _ ->
        false
    end
  end

  defp valid_input?(descriptor, identity) when is_map(descriptor) and is_map(identity) do
    # Defensive validation must not call the shared encoder until its validated-
    # input precondition is established. This bounded conversion interns no atoms.
    with true <- map_size(identity) == 4 and Storage.valid_identity?(identity),
         {:ok, wire} <- wire(descriptor, 0),
         {:ok, ^descriptor} <- Relocation.descriptor(Map.put(wire, "version", 3)),
         do: true,
         else: (_ -> false)
  end

  defp valid_input?(_, _), do: false

  defp wire(_, depth) when depth > 3, do: :error

  defp wire(value, depth) when is_map(value) and map_size(value) <= 16 do
    Enum.reduce_while(value, {:ok, %{}}, fn
      {key, item}, {:ok, acc} when is_atom(key) ->
        case wire(item, depth + 1) do
          {:ok, encoded} -> {:cont, {:ok, Map.put(acc, Atom.to_string(key), encoded)}}
          _ -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defp wire(nil, _), do: {:ok, nil}
  defp wire(value, _) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp wire(value, _) when is_integer(value), do: {:ok, value}
  defp wire(value, _) when is_binary(value) and byte_size(value) <= 256, do: {:ok, value}
  defp wire(_, _), do: :error

  defp binding(descriptor, identity) do
    descriptor
    |> Relocation.encode_descriptor()
    |> Map.delete("stream")
    |> Map.put("source_dataset_guid", descriptor.stream.source_dataset_guid)
    |> Map.put("local_storage", Storage.encode(identity))
  end

  defp encoded_stream(descriptor), do: Relocation.encode_descriptor(descriptor)["stream"]

  defp valid_record?(
         %{
           "version" => 1,
           "binding" => bound,
           "phase" => phase,
           "nonce" => nonce,
           "dataset_guid" => guid,
           "stream" => stream,
           "stream_state" => state
         } = record,
         descriptor,
         identity
       )
       when map_size(record) == 7 and is_map(stream) do
    wire = descriptor |> Relocation.encode_descriptor() |> Map.put("stream", stream)

    bound == binding(descriptor, identity) and phase in ["active", "retiring", "retired"] and
      is_binary(nonce) and Regex.match?(~r/\A[0-9a-f]{32}\z/, nonce) and
      (is_nil(guid) or Storage.guid?(guid)) and state in ["receiving", "received"] and
      (state != "received" or Storage.guid?(guid)) and
      match?({:ok, _}, Relocation.descriptor(wire)) and
      stream["source_dataset_guid"] == descriptor.stream.source_dataset_guid
  end

  defp valid_record?(_, _, _), do: false
  defp failure, do: {:error, :import_state_unconfirmed}
end
