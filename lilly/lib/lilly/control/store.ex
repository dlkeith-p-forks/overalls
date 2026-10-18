defmodule Lilly.Control.Store do
  @moduledoc "Host-bound durable latest intent per placement. The runtime must hold its OS lock while using this store."
  require Lilly.Events
  alias Lilly.Host.PrivateFiles

  @enforce_keys [:path, :host_id, :protocol_version]
  defstruct [:path, :host_id, :protocol_version]
  @type command :: OverallsProtocol.Execution.command()
  @type t :: %__MODULE__{path: Path.t(), host_id: OverallsProtocol.uuid(), protocol_version: 3}

  # @cc [owner:ghuntley,label:recovery] store-host-version-binding
  # open/3 MUST preserve the persistent host/version binding; changing either on an existing store
  # must fail instead of silently migrating receipt-only intent into executable intent.
  @spec open(Path.t(), OverallsProtocol.uuid(), 3) :: {:ok, t()} | {:error, atom()}
  def open(directory, host_id, version \\ 3) do
    binding = %{"version" => version, "host_id" => host_id}

    with :ok <- PrivateFiles.directory(directory),
         true <- OverallsProtocol.uuid?(host_id) and version == 3,
         :ok <- bind(directory, binding),
         path = Path.join(directory, "commands"),
         :ok <- PrivateFiles.directory(path) do
      {:ok, %__MODULE__{path: path, host_id: host_id, protocol_version: version}}
    else
      _ -> {:error, :invalid_state_store}
    end
  end

  # @cc [owner:ghuntley,label:recovery] durable-intent-monotonic-generations
  # accept/2 MUST preserve immutable VM/placement identity and the greatest stored
  # execution-epoch/generation pair; a higher generation in an older epoch is stale. Exact
  # duplicates are idempotent, equal-generation changes conflict, and stale delivery must not
  # replace newer intent. Success requires durable publication of the retained command.
  @spec accept(t(), command()) ::
          {:ok, :stored | :duplicate | :stale} | {:error, atom()}
  def accept(store, command) do
    codec = codec(store)

    with true <- is_map(command),
         {:ok, [^command]} <- codec.commands([codec.encode_command(command)]),
         true <- command.host_id == store.host_id,
         {:ok, existing} <- read(store, command.placement_id) do
      cond do
        existing == nil -> persist(store, command, :stored)
        existing == command -> persist(store, command, :duplicate)
        not transition?(existing, command) -> conflict(command, :vm_identity_conflict)
        revision(existing) > revision(command) -> persist(store, existing, :stale)
        revision(existing) == revision(command) -> conflict(command, :generation_conflict)
        existing.id == command.id -> conflict(command, :operation_conflict)
        true -> persist(store, command, :stored)
      end
    else
      _ -> {:error, :invalid_command}
    end
  end

  # @cc [owner:ghuntley,label:recovery;observability] intent-conflict-diagnostics-closed
  # Intent conflicts MUST report only the command's VM/placement identifiers and
  # the closed conflict reason atom; command payloads and stored records MUST
  # NOT be logged.
  defp conflict(command, reason) do
    Lilly.Events.emit("lilly.intent_conflict",
      vm_id: command.vm_id,
      placement_id: command.placement_id,
      reason: reason
    )

    {:error, reason}
  end

  @doc "Read the command for one physical placement, never by logical VM identity."
  @spec read(t(), OverallsProtocol.uuid()) ::
          {:ok, command() | nil} | {:error, atom()}
  def read(store, id) do
    if OverallsProtocol.uuid?(id) do
      path = Path.join(store.path, id <> ".json")
      codec = codec(store)

      case File.lstat(path) do
        {:error, :enoent} ->
          {:ok, nil}

        {:ok, %File.Stat{type: :regular, size: size, links: 1}} when size <= 16_384 ->
          with {:ok, encoded} <- PrivateFiles.read_secret(path),
               {:ok, %{"version" => version, "command" => value}} <-
                 OverallsProtocol.decode(encoded),
               true <- version == store.protocol_version,
               {:ok, [command]} <- codec.commands([value]),
               true <- command.placement_id == id and command.host_id == store.host_id do
            {:ok, command}
          else
            _ -> {:error, :invalid_stored_command}
          end

        _ ->
          {:error, :invalid_stored_command}
      end
    else
      {:error, :invalid_placement_id}
    end
  end

  @spec all(t()) :: {:ok, [command()]} | {:error, atom()}
  def all(store) do
    with {:ok, names} <- File.ls(store.path), true <- length(names) <= 8192 do
      names
      |> Enum.reject(&String.starts_with?(&1, ".pending-"))
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, commands} ->
        with true <- String.ends_with?(name, ".json"),
             id = String.trim_trailing(name, ".json"),
             {:ok, command} when not is_nil(command) <- read(store, id) do
          {:cont, {:ok, [command | commands]}}
        else
          _ -> {:halt, {:error, :invalid_stored_command}}
        end
      end)
    else
      _ -> {:error, :invalid_state_store}
    end
  end

  defp bind(directory, expected) do
    path = Path.join(directory, "identity.json")

    case File.lstat(path) do
      {:error, :enoent} ->
        PrivateFiles.write(directory, "identity.json", JSON.encode!(expected))

      {:ok, _} ->
        with {:ok, bytes} <- PrivateFiles.read_secret(path),
             {:ok, ^expected} <- JSON.decode(bytes),
             do: :ok,
             else: (_ -> {:error, :host_identity_mismatch})

      _ ->
        {:error, :host_identity_mismatch}
    end
  end

  defp persist(store, command, result) do
    codec = codec(store)

    encoded =
      JSON.encode!(%{
        "version" => store.protocol_version,
        "command" => codec.encode_command(command)
      })

    with :ok <- PrivateFiles.write(store.path, command.placement_id <> ".json", encoded),
         do: {:ok, result}
  end

  # @cc [owner:ghuntley,label:security] store-owner-metadata-monotonic
  # Every stored command carries its validated owner. The owner is immutable
  # placement identity: newer or stale intent with a different owner MUST be
  # refused as a conflict, never adopted or acknowledged as the stored record.
  defp transition?(existing, command),
    do: existing.owner_id == command.owner_id and identity_transition?(existing, command)

  # @cc [owner:ghuntley,label:security] store-resize-is-only-resource-rebinding
  # Resource changes MUST require a resize command bound to the previous stopped
  # shape, or the exact target of that recorded resize. Readiness request markers
  # (resize_id/clone_id), optional workspace_source reference (ADR-0128), and Git attribution
  # are operation metadata, not placement identity; changing them still requires
  # a newer generation and a distinct operation ID. All other
  # placement identity remains strict. The owner is governed separately by
  # store-owner-metadata-monotonic. Bootstrap SSH key material may
  # disappear after the initial provision command, but it MUST NOT be introduced,
  # restored or changed by later lifecycle intent.
  defp identity_transition?(existing, command) do
    source = Map.get(command, :resize_from)

    identity_valid =
      cond do
        command.kind == :resize ->
          Map.drop(immutable(existing), [
            :vcpu,
            :memory_bytes,
            :disk_bytes,
            :resize_from,
            :resize_id
          ]) ==
            Map.drop(immutable(command), [
              :vcpu,
              :memory_bytes,
              :disk_bytes,
              :resize_from,
              :resize_id
            ]) and
            ((existing.kind == :stop and source == OverallsProtocol.Resize.sizes(existing)) or
               (existing.kind == :resize and source == existing.resize_from and
                  command.resize_id == existing.resize_id and
                  OverallsProtocol.Resize.sizes(command) ==
                    OverallsProtocol.Resize.sizes(existing)))

        existing.kind == :resize ->
          Map.drop(immutable(existing), [:resize_from, :resize_id]) ==
            Map.delete(immutable(command), :resize_id)

        existing.kind == :pause and command.kind == :resume ->
          Map.drop(immutable(existing), [:slot]) == Map.drop(immutable(command), [:slot])

        true ->
          immutable(existing) == immutable(command)
      end

    identity_valid
  end

  defp immutable(command),
    do:
      Map.drop(command, [
        :id,
        :generation,
        :execution_epoch,
        :kind,
        :resize_id,
        :clone_id,
        :owner_id,
        :workspace_source,
        :git_identity,
        :checkpoint
      ])

  defp revision(command), do: {command.execution_epoch, command.generation}

  @doc "Retire confirmed deletion from active reconciliation; the driver/journal retain tombstones."
  # @cc [owner:ghuntley,label:assumption;recovery] retire-needs-acknowledged-cleanup
  # Callers of retire/2 MUST first obtain durable acknowledgement of the current deleted physical
  # outcome. retire/2 may remove only the matching current v3 delete command, while driver and
  # actor identity tombstones remain.
  @spec retire(t(), OverallsProtocol.Execution.command()) :: :ok | {:error, atom()}
  def retire(%{protocol_version: 3} = store, %{kind: :delete} = command) do
    with {:ok, ^command} <- read(store, command.placement_id),
         {:ok, _} <-
           Lilly.Host.Command.run(:rm, [
             "--",
             Path.join(store.path, command.placement_id <> ".json")
           ]),
         {:ok, _} <- Lilly.Host.Command.run(:sync, ["--", store.path]),
         do: :ok,
         else: (_ -> {:error, :command_store_failed})
  end

  def retire(_, _), do: {:error, :invalid_command}

  defp codec(%{protocol_version: 3}), do: OverallsProtocol.Execution
end
