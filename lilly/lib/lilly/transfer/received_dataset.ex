defmodule Lilly.Transfer.ReceivedDataset do
  @moduledoc "Verifies native staging against destination-local import intent; never adopts an executable disk."
  alias OverallsProtocol.DiskTransfer, as: Relocation
  alias Lilly.Host.{Command, Lock, Pool, PrivateFiles, ZFS, ZFSDataset}
  alias Lilly.Transfer.{ImportJournal, SnapshotJournal}
  @type failure :: {:error, :received_dataset_unconfirmed}

  # @cc [owner:ghuntley,label:recovery;security] owned-import-defers-pool-readiness
  # While holding the pool lock, an active private import journal with matching
  # local host/pool/placement/nonce and native GUID MAY defer readiness while its
  # stream may still be writing; once received it is staged (see staging/1),
  # not busy, until adoption or cleanup. Any ordinary claim ends that deferral. This grants neither
  # execution nor capacity credit; false MUST NOT substitute for normal validation.
  # Unbound receiving intent with native/path absence also defers: its stream may
  # start outside the pool lock. A missing previously bound dataset MUST NOT defer.
  # Unknown, foreign, malformed or replaced ownership MUST NOT be called busy.
  # Parent identity/policy verification MUST NOT require usage decomposition:
  # counters may be incoherent during receive. Normal readiness stays strict.
  @spec staging_busy?(Pool.t()) :: boolean()
  def staging_busy?(pool), do: staging(pool) == :busy

  @typedoc "A finished, owned, not yet adopted import: its child and expected snapshots."
  @type staged :: %{String.t() => Lilly.Host.ZFS.snapshots()}

  # @cc [owner:ghuntley,label:recovery;security] finished-import-is-staged-not-busy
  # Only an owned import whose stream may still be writing (receiving, or not
  # yet bound to a native GUID) defers pool readiness: usage counters may be
  # incoherent then. A finished receive is reported as staged: its child name
  # and the snapshot GUIDs its journal and descriptor fix, so restart readiness
  # can validate it under receive policy instead of refusing the whole pool.
  # Unknown, foreign or malformed staging is neither busy nor staged.
  @doc "Owned pool staging: `:busy` while a stream may be writing, else the finished imports."
  @spec staging(Pool.t()) :: :busy | {:ok, staged()}
  def staging(pool) do
    root = Path.join([pool.path, ".lilly-zfs", "imports"])
    identity = Pool.zfs_identity(pool)

    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         {:ok, entries} <- File.ls(root),
         true <- length(entries) <= 4096 and Enum.all?(entries, &OverallsProtocol.uuid?/1),
         true <- ZFS.staging_identity?(identity),
         {:ok, owners} <- ZFS.owners(identity) do
      Enum.reduce_while(entries, {:ok, %{}}, fn placement, {:ok, staged} ->
        case owned_staging(pool, placement, owners) do
          :busy -> {:halt, :busy}
          {:staged, name, snapshots} -> {:cont, {:ok, Map.put(staged, name, snapshots)}}
          :none -> {:cont, {:ok, staged}}
        end
      end)
    else
      _ -> {:ok, %{}}
    end
  end

  @spec owned_staging(Pool.t(), OverallsProtocol.uuid(), %{String.t() => map()}) ::
          :busy | {:staged, String.t(), Lilly.Host.ZFS.snapshots()} | :none
  defp owned_staging(pool, placement, owners) do
    name = pool.storage.dataset <> "/vm-" <> placement

    with {:ok, %{descriptor: descriptor, journal: %{"phase" => "active"} = journal}} <-
           ImportJournal.local(directory(pool, placement), pool.storage),
         true <-
           descriptor.destination == %{
             host_id: pool.host_id,
             pool_id: pool.id,
             placement_id: placement
           },
         true <- ordinary_claims_absent?(pool, placement) do
      case owners[name] do
        nil ->
          if journal["dataset_guid"] == nil and journal["stream_state"] == "receiving" and
               File.lstat(Path.join([pool.path, "vms", placement])) == {:error, :enoent},
             do: :busy,
             else: :none

        %{"guid" => guid} = owner ->
          owned? =
            owner["host"] == pool.host_id and owner["pool"] == pool.id and
              owner["vm"] == placement and owner["nonce"] == journal["nonce"] and
              journal["dataset_guid"] in [nil, guid]

          cond do
            not owned? ->
              :none

            journal["stream_state"] == "received" and journal["dataset_guid"] == guid ->
              {:staged, name, snapshots(name, guid, descriptor)}

            true ->
              :busy
          end

        _ ->
          :none
      end
    else
      _ -> :none
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] receive-intent-requires-native-preflight
  # prepare/2 requires the destination pool lock, current reservation/relocation
  # authority and quiescent streams. New intent MUST require native dataset and
  # canonical mountpoint absence, with no ordinary placement claim. Retained GUIDs
  # MUST NOT authorize replacement datasets; existing intent MUST name the same
  # single full stream (ADR-0155). Success persists intent only; it does not
  # authorize a stream, adoption or launch.
  @spec prepare(Pool.t(), Relocation.descriptor()) :: {:ok, ImportJournal.journal()} | failure()
  def prepare(
        pool,
        %{destination: %{placement_id: placement, host_id: host, pool_id: pool_id}} = descriptor
      ) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         true <- host == pool.host_id and pool_id == pool.id and OverallsProtocol.uuid?(placement),
         directory = directory(pool, placement),
         {:ok, journal} <- ImportJournal.read(directory, descriptor, pool.storage),
         true <- is_nil(journal) or journal["phase"] == "active",
         :ok <- ZFSDataset.bind(pool),
         true <- ordinary_claims_absent?(pool, placement),
         :ok <- prepare_native(pool, descriptor, journal),
         :ok <- PrivateFiles.directory(Path.dirname(directory)),
         {:ok, _} <- Command.run(:sync, ["--", Path.dirname(Path.dirname(directory))]),
         {:ok, prepared} <- ImportJournal.prepare(directory, descriptor, pool.storage) do
      {:ok, prepared}
    else
      _ -> {:error, :received_dataset_unconfirmed}
    end
  end

  def prepare(_, _), do: {:error, :received_dataset_unconfirmed}

  # @cc [owner:ghuntley,label:security;recovery] receiver-fields-from-local-intent
  # receiver/2 requires the pool lock, current relocation/reservation authority
  # and quiescent streams. It MUST require existing receiving intent, revalidate
  # native staging, and derive the target and ownership markers only from the
  # trusted pool and validated local journal. hostd adds the fixed receive
  # options that prevent mounting/execution and retain resumable state
  # (hostd-transfer-stream-typed). The returned descriptor does not prove
  # stream authority, completed receive, adoption or guest execution permission.
  @spec receiver(Pool.t(), Relocation.descriptor()) ::
          {:ok, Lilly.Transfer.Stream.consumer()} | failure()
  def receiver(
        pool,
        %{destination: %{placement_id: placement, host_id: host, pool_id: pool_id}} = descriptor
      ) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         true <- host == pool.host_id and pool_id == pool.id and OverallsProtocol.uuid?(placement),
         {:ok, %{"phase" => "active", "stream_state" => "receiving"} = journal} <-
           ImportJournal.read(
             directory(pool, descriptor.destination.placement_id),
             descriptor,
             pool.storage
           ),
         true <- journal["stream"] == Relocation.encode_descriptor(descriptor)["stream"],
         {:ok, ^journal} <- prepare(pool, descriptor) do
      {:ok,
       {:receive,
        %{
          dataset: pool.storage.dataset,
          pool: pool.path,
          placement: descriptor.destination.placement_id,
          host: pool.host_id,
          pool_id: pool.id,
          nonce: journal["nonce"]
        }}}
    else
      _ -> {:error, :received_dataset_unconfirmed}
    end
  end

  def receiver(_, _), do: {:error, :received_dataset_unconfirmed}

  # @cc [owner:ghuntley,label:security;recovery] fresh-receive-rejects-partial-state
  # fresh_receiver/2 has receiver/2's authority, locking and quiescence preconditions.
  # An ordinary full send MUST require native absence and no bound local GUID.
  # A failed resume lookup alone MUST NOT authorize ordinary replay.
  # Unknown/replaced state fails.
  @spec fresh_receiver(Pool.t(), Relocation.descriptor()) ::
          {:ok, Lilly.Transfer.Stream.consumer()} | failure()
  def fresh_receiver(pool, descriptor) do
    with {:ok, command} <- receiver(pool, descriptor),
         {:ok, journal} <-
           ImportJournal.read(
             directory(pool, descriptor.destination.placement_id),
             descriptor,
             pool.storage
           ),
         :ok <- fresh_state(pool, descriptor, journal),
         do: {:ok, command},
         else: (_ -> {:error, :received_dataset_unconfirmed})
  end

  defp fresh_state(pool, descriptor, journal) do
    name = pool.storage.dataset <> "/vm-" <> descriptor.destination.placement_id

    with true <- is_nil(journal["dataset_guid"]),
         :ok <- ZFS.absent_child(Pool.zfs_identity(pool), name),
         do: :ok,
         else: (_ -> :error)
  end

  defp prepare_native(pool, descriptor, nil) do
    placement = descriptor.destination.placement_id
    name = pool.storage.dataset <> "/vm-" <> placement

    with {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)),
         false <- Map.has_key?(owners, name),
         {:error, :enoent} <- File.lstat(Path.join([pool.path, "vms", placement])),
         do: :ok,
         else: (_ -> :error)
  end

  defp prepare_native(pool, descriptor, journal) do
    wire = Relocation.encode_descriptor(descriptor)

    cond do
      journal["stream"] == wire["stream"] and journal["stream_state"] == "receiving" ->
        placement = descriptor.destination.placement_id
        name = pool.storage.dataset <> "/vm-" <> placement

        with {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)) do
          case owners[name] do
            nil ->
              if is_nil(journal["dataset_guid"]), do: :ok, else: :error

            %{"guid" => guid} ->
              if journal["dataset_guid"] in [nil, guid] and
                   local_owner?(pool, placement, journal["nonce"]),
                 do: :ok,
                 else: :error
          end
        end

      journal["stream"] == wire["stream"] ->
        with {:ok, _} <- verify(pool, descriptor), do: :ok

      true ->
        :error
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] receive-receipt-joins-local-and-native-identity
  # verify/2 requires the destination pool lock, current relocation/reservation and
  # confirmed stream quiescence. It MUST read pre-existing local intent outside
  # portable data, reject ordinary active/deleted placement claims, verify local
  # host/pool/placement/nonce markers and exact native GUID lineage before recording
  # receipt. Missing journals MUST NOT be reconstructed from received properties.
  # Success is staging receipt only: rootfs shape, image compatibility, activation,
  # reservation credit, readiness, handoff and source cleanup remain separate.
  @spec verify(Pool.t(), Relocation.descriptor()) :: {:ok, ImportJournal.journal()} | failure()
  def verify(
        pool,
        %{destination: %{placement_id: placement, host_id: host, pool_id: pool_id}} = descriptor
      ) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         true <- host == pool.host_id and pool_id == pool.id and OverallsProtocol.uuid?(placement),
         directory = directory(pool, placement),
         {:ok, %{"phase" => "active"} = journal} <-
           ImportJournal.read(directory, descriptor, pool.storage),
         true <- journal["stream"] == Relocation.encode_descriptor(descriptor)["stream"],
         :ok <- ZFSDataset.bind(pool),
         true <- ordinary_claims_absent?(pool, placement),
         name = pool.storage.dataset <> "/vm-" <> placement,
         {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)),
         %{"guid" => guid} <- owners[name],
         true <- journal["dataset_guid"] in [nil, guid],
         true <- local_owner?(pool, placement, journal["nonce"]),
         snapshots = snapshots(name, guid, descriptor),
         :ok <- ZFS.receive_child(Pool.zfs_identity(pool), name, guid, snapshots),
         true <- local_owner?(pool, placement, journal["nonce"]),
         {:ok, _} <-
           ImportJournal.bind(directory, descriptor, pool.storage, journal["nonce"], guid),
         {:ok, received} <-
           ImportJournal.received(
             directory,
             descriptor,
             pool.storage,
             guid,
             descriptor.stream.to_guid
           ) do
      {:ok, received}
    else
      _ -> {:error, :received_dataset_unconfirmed}
    end
  end

  def verify(_, _), do: {:error, :received_dataset_unconfirmed}

  # @cc [owner:ghuntley,label:security;recovery] destination-resume-token-is-owned-staging
  # resume_token/2 requires the pool lock, current relocation/reservation authority
  # and confirmed stream quiescence. It MUST require existing active receiving
  # intent for this exact stream, no ordinary claims, local nonce ownership and
  # unchanged native GUID/safe staging policy with no retained snapshot. Bind the
  # destination GUID before returning a bounded
  # opaque token; callers MUST validate its source lineage before authorizing send.
  # No receipt, adoption, execution or capacity credit is granted.
  @spec resume_token(Pool.t(), Relocation.descriptor()) :: {:ok, String.t()} | failure()
  def resume_token(
        pool,
        %{destination: %{placement_id: placement, host_id: host, pool_id: pool_id}} = descriptor
      ) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         true <- host == pool.host_id and pool_id == pool.id and OverallsProtocol.uuid?(placement),
         directory = directory(pool, placement),
         {:ok, %{"phase" => "active", "stream_state" => "receiving"} = journal} <-
           ImportJournal.read(directory, descriptor, pool.storage),
         true <- journal["stream"] == Relocation.encode_descriptor(descriptor)["stream"],
         :ok <- ZFSDataset.bind(pool),
         true <- ordinary_claims_absent?(pool, placement),
         name = pool.storage.dataset <> "/vm-" <> placement,
         {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)),
         %{"guid" => guid} <- owners[name],
         true <- journal["dataset_guid"] in [nil, guid],
         true <- local_owner?(pool, placement, journal["nonce"]),
         {:ok, token} <- ZFS.resume_child(Pool.zfs_identity(pool), name, guid, %{}),
         true <- local_owner?(pool, placement, journal["nonce"]),
         {:ok, _} <-
           ImportJournal.bind(directory, descriptor, pool.storage, journal["nonce"], guid) do
      {:ok, token}
    else
      _ -> {:error, :received_dataset_unconfirmed}
    end
  end

  def resume_token(_, _), do: {:error, :received_dataset_unconfirmed}

  @doc "Trusted pool-derived local import directory, outside the portable child dataset."
  # @cc [owner:ghuntley,label:security] import-path-is-placement-derived
  # directory/2 MUST reject a non-UUID placement before deriving a path beneath the
  # trusted pool's host metadata. Peer-provided paths MUST NOT select import state.
  @spec directory(Pool.t(), OverallsProtocol.uuid()) :: Path.t()
  def directory(pool, placement) do
    true = OverallsProtocol.uuid?(placement)
    Path.join([pool.path, ".lilly-zfs", "imports", placement])
  end

  defp ordinary_claims_absent?(pool, placement) do
    Enum.all?(["active", "deleted"], fn state ->
      File.lstat(Path.join([pool.path, ".lilly-zfs", state, placement])) == {:error, :enoent}
    end)
  end

  @doc "Local receive markers only; callers must separately verify the journal, native GUID and policy."
  @spec local_owner?(Pool.t(), OverallsProtocol.uuid(), String.t()) :: boolean()
  def local_owner?(pool, placement, nonce) do
    name = pool.storage.dataset <> "/vm-" <> placement

    expected = %{
      "lilly:host" => pool.host_id,
      "lilly:pool" => pool.id,
      "lilly:vm" => placement,
      "lilly:nonce" => nonce
    }

    with {:ok, output} <-
           Command.run(:zfs_get, [
             "-Hp",
             "-o",
             "property,value,source",
             "lilly:host,lilly:pool,lilly:vm,lilly:nonce",
             name
           ]),
         rows = output |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, "\t")),
         true <- length(rows) == 4 do
      Enum.all?(expected, fn {key, value} -> [key, value, "local"] in rows end)
    else
      _ -> false
    end
  end

  @doc "The one received snapshot a full stream leaves: the source's transfer snapshot."
  @spec snapshots(String.t(), String.t(), Relocation.descriptor()) :: Lilly.Host.ZFS.snapshots()
  def snapshots(name, guid, descriptor),
    do: %{
      (name <> "@" <> SnapshotJournal.slot()) => %{
        dataset_guid: guid,
        snapshot_guid: descriptor.stream.to_guid
      }
    }
end
