defmodule Lilly.Transfer.SnapshotJournal do
  @moduledoc "Durable local intent and GUID binding for one transfer's single source snapshot."
  require Lilly.Events
  alias OverallsProtocol.Storage
  alias Lilly.Host.{Command, Lock, PrivateFiles}
  @filename "snapshots.json"
  @maximum 9_223_372_036_854_775_807
  @ids ~w(host_id pool_id placement_id relocation_id)a
  @guids ~w(zpool_guid parent_dataset_guid dataset_guid)a
  # The one native snapshot name per transfer (ADR-0155 removed the "lilly-a"
  # running-source baseline). Native policy still recognizes "lilly-b".
  @slot "lilly-b"
  @type binding :: %{
          host_id: OverallsProtocol.uuid(),
          pool_id: OverallsProtocol.uuid(),
          placement_id: OverallsProtocol.uuid(),
          relocation_id: OverallsProtocol.uuid(),
          zpool_guid: String.t(),
          parent_dataset_guid: String.t(),
          dataset_guid: String.t(),
          execution_epoch: pos_integer()
        }
  @type journal :: %{String.t() => term()}
  @type failure :: {:error, :snapshot_state_unconfirmed}

  @doc "Decode the closed local binding without creating atoms from persisted keys."
  @spec decode_binding(term()) :: {:ok, binding()} | failure()
  def decode_binding(value) when is_map(value) and map_size(value) == 8 do
    binding =
      Map.new(@ids ++ @guids ++ [:execution_epoch], fn key ->
        {key, value[Atom.to_string(key)]}
      end)

    if valid_binding?(binding), do: {:ok, binding}, else: failure()
  end

  def decode_binding(_), do: failure()

  # @cc [owner:ghuntley,label:recovery;security] snapshot-intent-before-native-create
  # prepare/2 MUST persist a fresh nonce before permitting native snapshot creation,
  # reuse the same intent on retry, and reject rebinding or retirement. Callers
  # MUST hold the pool mutation lock, verify the bound disk's local ownership and
  # prove physical stop before creation (ADR-0155: the single snapshot is always
  # of a stopped disk, so it needs no divergence headroom). The directory MUST be
  # derived from trusted host-local state outside portable data.
  @spec prepare(Path.t(), binding()) :: {:ok, journal()} | failure()
  def prepare(directory, binding) do
    mutate(directory, binding, fn record ->
      case record do
        %{"phase" => "active", "snapshots" => %{@slot => %{"state" => state}}}
        when state in ["creating", "ready"] ->
          {:ok, record}

        %{"phase" => "active", "snapshots" => slots} when map_size(slots) == 0 ->
          slot = %{
            "state" => "creating",
            "nonce" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
            "guid" => nil
          }

          {:ok, put_in(record, ["snapshots", @slot], slot)}

        _ ->
          :error
      end
    end)
  end

  @doc "The single native snapshot suffix every transfer journal binds."
  @spec slot() :: String.t()
  def slot, do: @slot

  # @cc [owner:ghuntley,label:recovery;security] snapshot-guid-bound-once
  # bind/5 MUST match the persisted nonce and bind a native GUID at most once.
  # Callers MUST first verify the native snapshot's creation nonce, dataset ownership
  # and exact name under the pool lock. A retiring unbound create MAY acquire its GUID
  # solely for cleanup; binding MUST NOT restore permission to create or transfer.
  @spec bind(Path.t(), binding(), String.t(), String.t()) :: {:ok, journal()} | failure()
  def bind(directory, binding, nonce, guid) do
    mutate(directory, binding, fn record ->
      with true <- Storage.guid?(guid),
           %{"nonce" => ^nonce, "guid" => previous, "state" => state} = slot <-
             record["snapshots"][@slot],
           true <- record["phase"] in ["active", "retiring"],
           true <- state in ["creating", "ready", "deleting"],
           true <- is_nil(previous) or previous == guid,
           state = if(state == "creating", do: "ready", else: state) do
        {:ok, put_in(record, ["snapshots", @slot], %{slot | "guid" => guid, "state" => state})}
      else
        _ -> :error
      end
    end)
  end

  # @cc [owner:ghuntley,label:recovery] snapshot-retirement-fences-all-creation
  # begin_retire/2 MUST atomically fence the slot before native deletion, including
  # cancellation before the first create. Interrupted creates retain their nonce for
  # recovery and cleanup. Delayed prepare calls MUST NOT resurrect retiring snapshots.
  # The caller MUST separately stop/reap streams before deleting snapshots they use.
  @spec begin_retire(Path.t(), binding()) :: {:ok, journal()} | failure()
  def begin_retire(directory, binding) do
    mutate(directory, binding, fn record ->
      if record["phase"] == "retired" do
        {:ok, record}
      else
        snapshots =
          Map.new(record["snapshots"], fn {name, slot} ->
            state = if slot["state"] == "deleted", do: "deleted", else: "deleting"
            {name, %{slot | "state" => state}}
          end)

        {:ok, %{record | "phase" => "retiring", "snapshots" => snapshots}}
      end
    end)
  end

  # @cc [owner:ghuntley,label:recovery] snapshot-deletion-requires-native-absence
  # deleted/3 MUST accept only the exact recorded GUID after a retirement fence.
  # The caller MUST confirm native absence under the pool lock first; nil is permitted
  # only for a create that never acquired a GUID. This journal is not physical proof.
  # finish_retire/2 MUST preserve a tombstone and reject any unconfirmed slot.
  @spec deleted(Path.t(), binding(), String.t() | nil) :: {:ok, journal()} | failure()
  def deleted(directory, binding, guid) do
    reported(
      mutate(directory, binding, fn record ->
        with true <- record["phase"] in ["retiring", "retired"],
             %{"guid" => ^guid, "state" => state} = slot <- record["snapshots"][@slot],
             true <- state in ["deleting", "deleted"] do
          {:ok, put_in(record, ["snapshots", @slot], %{slot | "state" => "deleted"})}
        else
          _ -> :error
        end
      end)
    )
  end

  # @cc [owner:ghuntley,label:security;observability] snapshot-journal-failure-diagnostics-closed
  # A failed durable snapshot-journal mutation MUST report only the closed
  # journal reason atom; bindings, nonces, GUIDs and slot payloads MUST NOT be
  # logged. Owning retry loops keep their own deduplicated diagnostics, so
  # repeated failures here are bounded by the caller's lease.
  defp reported({:ok, _} = ok), do: ok

  defp reported({:error, reason} = error) do
    Lilly.Events.emit("lilly.transfer_effect_failed", reason: reason)
    error
  end

  @spec finish_retire(Path.t(), binding()) :: {:ok, journal()} | failure()
  def finish_retire(directory, binding) do
    mutate(directory, binding, fn record ->
      if record["phase"] in ["retiring", "retired"] and
           Enum.all?(record["snapshots"], fn {_, slot} -> slot["state"] == "deleted" end),
         do: {:ok, %{record | "phase" => "retired"}},
         else: :error
    end)
  end

  # @cc [owner:ghuntley,label:security] snapshot-journal-is-not-peer-ownership
  # read/2 MUST reject unsafe files, unknown fields, malformed state and any binding
  # mismatch. Missing state MUST remain absent, never be interpreted as ownership.
  # Callers using observations as authority MUST hold the pool lock and independently
  # match the native dataset and durable disk claim; copying this file is not adoption.
  @spec read(Path.t(), binding()) :: {:ok, journal() | nil} | failure()
  def read(directory, binding) do
    with true <- valid_binding?(binding) do
      case File.lstat(Path.join(directory, @filename)) do
        {:error, :enoent} ->
          {:ok, nil}

        {:ok, _} ->
          with {:ok, bytes} <- PrivateFiles.read_secret(Path.join(directory, @filename)),
               {:ok, record} <- Lilly.Lifecycle.Journal.decode(bytes),
               true <- valid_record?(record, binding),
               do: {:ok, record},
               else: (_ -> failure())

        _ ->
          failure()
      end
    else
      _ -> failure()
    end
  end

  @doc "Bound snapshot suffixes only; the caller derives native paths from its verified pool/placement."
  # @cc [owner:ghuntley,label:capacity] snapshot-expectations-withhold-uncertain-creates
  # expectations/2 MUST withhold missing journals and unbound/in-progress creates.
  # GUID-bound deleting slots remain expected until native absence is confirmed.
  # Deleted slots grant no expectation; the native reader must still reject extras.
  # Returned bindings MUST NOT independently grant allocation credit or cleanup authority.
  @spec expectations(Path.t(), binding()) :: {:ok, %{String.t() => map()}} | failure()
  def expectations(directory, binding) do
    with {:ok, record} when is_map(record) <- read(directory, binding) do
      Enum.reduce_while(record["snapshots"], {:ok, %{}}, fn {name, slot}, {:ok, acc} ->
        case slot do
          %{"state" => "deleted"} ->
            {:cont, {:ok, acc}}

          %{"state" => state, "guid" => guid}
          when state in ["ready", "deleting"] and is_binary(guid) ->
            {:cont,
             {:ok, Map.put(acc, name, %{dataset_guid: binding.dataset_guid, snapshot_guid: guid})}}

          _ ->
            {:halt, failure()}
        end
      end)
    else
      _ -> failure()
    end
  end

  defp mutate(directory, binding, function) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         {:ok, existing} <- read(directory, binding),
         {:ok, record} <- initialize(directory, binding, existing),
         {:ok, updated} <- function.(record),
         true <- valid_record?(updated, binding),
         :ok <-
           Lilly.Lifecycle.Journal.write(
             Lilly.Lifecycle.SnapshotSet,
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

  defp initialize(directory, binding, nil) do
    with {:ok, names} <- File.ls(directory),
         true <- Enum.all?(names, &initial_file?(directory, &1)) do
      {:ok,
       %{"version" => 1, "binding" => encode(binding), "phase" => "active", "snapshots" => %{}}}
    else
      {:error, :enoent} ->
        {:ok,
         %{"version" => 1, "binding" => encode(binding), "phase" => "active", "snapshots" => %{}}}

      _ ->
        failure()
    end
  end

  defp initialize(_directory, _binding, record), do: {:ok, record}

  defp initial_file?(_directory, "owner.lock"), do: true

  defp initial_file?(directory, name) do
    # An unpublished PrivateFiles temporary has never authorized a native effect.
    # Ignore only its exact private-file shape; never adopt its contents as intent.
    Regex.match?(~r/\A\.pending-[A-Za-z0-9_-]{16}\z/, name) and
      match?({:ok, _}, PrivateFiles.read_secret(Path.join(directory, name)))
  end

  defp valid_binding?(binding) when is_map(binding) and map_size(binding) == 8 do
    Enum.all?(@ids, &OverallsProtocol.uuid?(binding[&1])) and
      Enum.all?(@guids, &Storage.guid?(binding[&1])) and
      is_integer(binding[:execution_epoch]) and binding.execution_epoch in 1..@maximum
  end

  defp valid_binding?(_), do: false

  defp valid_record?(
         %{"version" => 1, "binding" => bound, "phase" => phase, "snapshots" => slots} = record,
         binding
       )
       when map_size(record) == 4 and is_map(slots) and map_size(slots) <= 1 do
    bound == encode(binding) and phase in ["active", "retiring", "retired"] and
      Enum.all?(slots, fn {name, slot} -> name == @slot and valid_slot?(slot, phase) end) and
      (phase != "active" or map_size(slots) == 1)
  end

  defp valid_record?(_, _), do: false

  defp valid_slot?(%{"state" => state, "guid" => guid, "nonce" => nonce} = slot, phase)
       when map_size(slot) == 3 do
    allowed =
      case phase do
        "active" -> state in ["creating", "ready"]
        "retiring" -> state in ["deleting", "deleted"]
        "retired" -> state == "deleted"
        _ -> false
      end

    allowed and is_binary(nonce) and Regex.match?(~r/\A[0-9a-f]{32}\z/, nonce) and
      case state do
        "creating" -> is_nil(guid)
        "ready" -> Storage.guid?(guid)
        _ -> is_nil(guid) or Storage.guid?(guid)
      end
  end

  defp valid_slot?(_, _), do: false
  defp encode(binding), do: Map.new(binding, fn {key, value} -> {Atom.to_string(key), value} end)
  defp failure, do: {:error, :snapshot_state_unconfirmed}
end
