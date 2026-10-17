defmodule Lilly.Transfer.SnapshotIndex do
  @moduledoc "One current source snapshot journal per placement, with retained relocation history."
  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.Transfer.SnapshotJournal, as: Journal
  @filename "snapshot-current.json"
  @fields ~w(host_id pool_id placement_id relocation_id zpool_guid parent_dataset_guid dataset_guid execution_epoch)a
  @type current :: %{binding: Journal.binding(), journal: Journal.journal(), directory: Path.t()}
  @type failure :: {:error, :snapshot_index_unconfirmed}

  # @cc [owner:ghuntley,label:recovery;security] snapshot-index-before-native-effects
  # prepare/3 MUST durably publish both the placement pointer and journal intent
  # before success. An initializing pointer precedes the journal, then becomes bound;
  # interruption may resume only the same binding. Bound pointers MUST NOT downgrade
  # or recreate a missing journal. A relocation-only chain requires a retired predecessor, a strictly
  # newer epoch and unchanged physical identities. Clone transitions may reuse the
  # same epoch only with a new transfer ID after full predecessor retirement;
  # authenticated clone creation still requires current driver generation fencing. Missing pointers with retained
  # history MUST fail, not reset authority. Callers MUST hold the pool lock and
  # verify disk ownership and current execution authority. Relocation snapshots
  # require a physically stopped source and MUST NOT require temporary headroom.
  # Metadata is an existing trusted disk-claim directory outside portable data.
  @spec prepare(Path.t(), Journal.binding()) :: {:ok, current()} | failure()
  @spec prepare(Path.t(), Journal.binding(), :relocation | :clone) ::
          {:ok, current()} | failure()
  def prepare(metadata, binding, purpose \\ :relocation)

  def prepare(metadata, binding, purpose) when purpose in [:relocation, :clone] do
    select(metadata, binding, purpose, fn directory -> Journal.prepare(directory, binding) end)
  end

  def prepare(_, _, _), do: failure()

  # @cc [owner:ghuntley,label:recovery] stale-retirement-does-not-regress-snapshot-index
  # begin_retire/2 MUST fence the selected journal before native cleanup. A late
  # retry of an already retired historical journal MAY return its tombstone, but
  # MUST NOT change the pointer or authorize deletion by a reused snapshot name.
  # A competing unfinished journal or regressed epoch MUST be rejected. Reusing
  # an epoch requires an explicitly marked clone transition and a fresh ID.
  @spec begin_retire(Path.t(), Journal.binding()) :: {:ok, current()} | failure()
  @spec begin_retire(Path.t(), Journal.binding(), :relocation | :clone) ::
          {:ok, current()} | failure()
  def begin_retire(metadata, binding, purpose \\ :relocation) do
    with :ok <- writable(metadata, binding),
         {:ok, pointer} <- pointer(metadata) do
      directory = directory(metadata, binding.relocation_id)

      case Journal.read(directory, binding) do
        {:ok, %{"phase" => "retired"} = journal} ->
          with true <- is_nil(pointer) or same_placement?(pointer.binding, binding),
               do: {:ok, %{directory: directory, binding: binding, journal: journal}},
               else: (_ -> failure())

        _ ->
          select(metadata, binding, purpose, fn directory ->
            Journal.begin_retire(directory, binding)
          end)
      end
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security;capacity] snapshot-current-requires-bound-journal
  # current/1 MUST reject unsafe/corrupt pointers, missing/mismatched journals and
  # unknown fields. Pointer absence is valid only without retained journal history;
  # it is not proof of native snapshot absence. Pool readers MUST reject native
  # snapshots lacking verified expectations. Authority consumers hold the pool lock.
  @spec current(Path.t()) :: {:ok, current() | nil} | failure()
  def current(metadata) do
    case pointer(metadata) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %{state: "bound", binding: binding}} ->
        directory = directory(metadata, binding.relocation_id)

        with {:ok, journal} when is_map(journal) <- Journal.read(directory, binding),
             do: {:ok, %{directory: directory, binding: binding, journal: journal}},
             else: (_ -> failure())

      _ ->
        failure()
    end
  end

  defp select(metadata, binding, purpose, operation) do
    with :ok <- writable(metadata, binding),
         {:ok, pointer} <- pointer(metadata),
         {:ok, mode} <- selectable(metadata, pointer, binding, purpose),
         :ok <- PrivateFiles.directory(Path.join(metadata, "transfers")),
         :ok <-
           if(mode == :initialize,
             do: save_pointer(metadata, binding, "initializing", purpose),
             else: :ok
           ),
         directory = directory(metadata, binding.relocation_id),
         {:ok, journal} <- operation.(directory),
         :ok <-
           if(mode == :existing, do: :ok, else: save_pointer(metadata, binding, "bound", purpose)) do
      # Never downgrade a bound pointer: a missing published journal is lost
      # authority, not an interrupted initial publication that may be recreated.
      {:ok, %{directory: directory, binding: binding, journal: journal}}
    else
      _ -> failure()
    end
  end

  defp save_pointer(metadata, binding, state, purpose) do
    value = %{"version" => 1, "binding" => encode(binding), "state" => state}
    value = if purpose == :clone, do: Map.put(value, "purpose", "clone"), else: value
    Lilly.Lifecycle.Journal.write(Lilly.Lifecycle.SnapshotPointer, metadata, @filename, value)
  end

  defp pointer(metadata) do
    case File.lstat(Path.join(metadata, @filename)) do
      {:error, :enoent} ->
        if empty_history?(metadata), do: {:ok, nil}, else: failure()

      {:ok, _} ->
        with {:ok, bytes} <- PrivateFiles.read_secret(Path.join(metadata, @filename)),
             {:ok, %{"version" => 1, "binding" => value, "state" => state} = pointer} <-
               Lilly.Lifecycle.Journal.decode(bytes),
             true <-
               (map_size(pointer) == 3 or
                  (map_size(pointer) == 4 and pointer["purpose"] == "clone")) and
                 state in ["initializing", "bound"],
             {:ok, binding} <- Journal.decode_binding(value),
             do:
               {:ok,
                %{
                  state: state,
                  binding: binding,
                  purpose: if(pointer["purpose"] == "clone", do: :clone, else: :relocation)
                }},
             else: (_ -> failure())

      _ ->
        failure()
    end
  end

  defp empty_history?(metadata) do
    parent = Path.join(metadata, "transfers")

    case File.lstat(parent) do
      {:error, :enoent} ->
        true

      {:ok, %File.Stat{type: :directory}} ->
        PrivateFiles.directory(parent) == :ok and File.ls(parent) == {:ok, []}

      _ ->
        false
    end
  end

  defp writable(metadata, binding) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         true <- is_map(binding),
         {:ok, ^binding} <- Journal.decode_binding(encode(binding)),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(metadata),
         :ok <- PrivateFiles.directory(metadata),
         do: :ok,
         else: (_ -> failure())
  end

  defp selectable(_metadata, nil, _binding, _purpose), do: {:ok, :initialize}

  defp selectable(
         _metadata,
         %{state: "initializing", binding: binding, purpose: purpose},
         binding,
         purpose
       ),
       do: {:ok, :resume}

  defp selectable(
         metadata,
         %{state: "bound", binding: binding, purpose: purpose},
         binding,
         purpose
       ) do
    with {:ok, journal} when is_map(journal) <-
           Journal.read(directory(metadata, binding.relocation_id), binding),
         do: {:ok, :existing},
         else: (_ -> failure())
  end

  defp selectable(metadata, %{state: "bound", binding: previous} = pointer, binding, purpose) do
    with true <- same_placement?(previous, binding),
         true <- purpose in [:relocation, :clone],
         true <-
           binding.execution_epoch > previous.execution_epoch or
             (binding.execution_epoch == previous.execution_epoch and
                (purpose == :clone or pointer.purpose == :clone)),
         true <- binding.relocation_id != previous.relocation_id,
         {:error, :enoent} <- File.lstat(directory(metadata, binding.relocation_id)),
         {:ok, %{"phase" => "retired"}} <-
           Journal.read(directory(metadata, previous.relocation_id), previous),
         do: {:ok, :initialize},
         else: (_ -> failure())
  end

  defp selectable(_, _, _, _), do: failure()

  defp same_placement?(left, right),
    do:
      Map.drop(left, [:relocation_id, :execution_epoch]) ==
        Map.drop(right, [:relocation_id, :execution_epoch])

  defp directory(metadata, relocation), do: Path.join([metadata, "transfers", relocation])
  defp encode(binding), do: Map.new(@fields, fn key -> {Atom.to_string(key), binding[key]} end)
  defp failure, do: {:error, :snapshot_index_unconfirmed}
end
