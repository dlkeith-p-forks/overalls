defmodule Lilly.Lifecycle.Journal do
  @moduledoc "State-only version-2 lifecycle envelopes."
  alias Lilly.Host.{Lock, PrivateFiles}
  @maximum 9_223_372_036_854_775_807

  # @cc [owner:ghuntley,label:durability;security] local-machine-locked-publication
  # Every mutation MUST hold an OS lock, reload the current envelope, and use an
  # Ash transition. State and revision MUST publish in one durable file;
  # malformed existing envelopes MUST NOT be replaced by fresh state.
  @spec write(module(), Path.t(), String.t(), map()) :: :ok | {:error, atom()}
  def write(resource, directory, filename, payload) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         true <- Lock.held?(port),
         {:ok, previous} <- load(resource, directory, filename),
         {:ok, state} <- state(resource, payload),
         true <-
           previous != nil or
             state in AshStateMachine.Info.state_machine_initial_states!(resource) do
      result =
        if previous do
          if previous.payload == payload do
            {:ok, previous}
          else
            previous
            |> Ash.Changeset.for_update(action(resource, :update, state), %{payload: payload})
            |> Ash.update()
          end
        else
          resource
          |> Ash.Changeset.for_create(action(resource, :create, state), %{
            id: Ash.UUID.generate(),
            directory: directory,
            filename: filename,
            payload: payload
          })
          |> Ash.create()
        end

      case result do
        {:ok, _} -> :ok
        _ -> {:error, :lifecycle_transition_unconfirmed}
      end
    else
      _ -> {:error, :lifecycle_transition_unconfirmed}
    end
  end

  @spec load(module(), Path.t(), String.t()) :: {:ok, struct() | nil} | {:error, atom()}
  def load(resource, directory, filename) do
    case File.lstat(Path.join(directory, filename)) do
      {:error, :enoent} ->
        {:ok, nil}

      {:ok, _} ->
        with {:ok, bytes} <- PrivateFiles.read_secret(Path.join(directory, filename)),
             {:ok, payload, metadata} <- envelope(bytes),
             true <- metadata["resource"] == resource_name(resource),
             true <- resource.valid_payload?(payload),
             {:ok, state} <- state(resource, payload),
             true <- metadata["state"] == Atom.to_string(state) do
          {:ok,
           struct(resource,
             id: metadata["id"],
             directory: directory,
             filename: filename,
             payload: payload,
             revision: metadata["revision"],
             state: state
           )}
        else
          _ -> {:error, :invalid_lifecycle_journal}
        end

      _ ->
        {:error, :invalid_lifecycle_journal}
    end
  end

  @spec decode(binary()) :: {:ok, map()} | {:error, atom()}
  def decode(bytes) do
    with {:ok, payload, _} <- envelope(bytes), do: {:ok, payload}
  end

  @spec envelope(binary()) :: {:ok, map(), map()} | {:error, atom()}
  def envelope(bytes) do
    with {:ok, %{"_lifecycle" => metadata} = value} <- JSON.decode(bytes),
         %{
           "resource" => resource,
           "id" => id,
           "state" => state,
           "revision" => revision
         } <- metadata,
         true <- valid_metadata?(metadata) and OverallsProtocol.uuid?(id),
         true <- is_binary(resource) and byte_size(resource) <= 64,
         true <- is_binary(state) and byte_size(state) <= 64,
         true <- is_integer(revision) and revision in 1..@maximum,
         resource when not is_nil(resource) <- resource_module(resource),
         {:ok, expected} <- state(resource, value),
         true <- state == Atom.to_string(expected) do
      {:ok, Map.delete(value, "_lifecycle"), metadata}
    else
      _ -> {:error, :invalid_lifecycle_journal}
    end
  end

  @spec valid_metadata?(term()) :: boolean()
  defp valid_metadata?(%{"version" => 2} = metadata),
    do: Enum.sort(Map.keys(metadata)) == Enum.sort(~w(version resource id state revision))

  defp valid_metadata?(_), do: false

  @spec state(module(), map()) :: {:ok, atom()} | {:error, atom()}
  def state(resource, payload) do
    wire = wire_state(resource, payload)

    case Enum.find(
           AshStateMachine.Info.state_machine_all_states(resource),
           &(Atom.to_string(&1) == wire)
         ) do
      nil -> {:error, :invalid_lifecycle_state}
      state -> {:ok, state}
    end
  end

  defp wire_state(Lilly.Lifecycle.SnapshotSet, %{"phase" => "active", "snapshots" => slots}) do
    case slots do
      %{"lilly-b" => %{"state" => state}} when map_size(slots) == 1 -> state
      _ -> nil
    end
  end

  defp wire_state(Lilly.Lifecycle.Import, %{"phase" => "active", "stream_state" => state}),
    do: state

  defp wire_state(_, payload), do: payload["state"] || payload["phase"]

  defp resource_module(name) do
    Enum.find(Ash.Domain.Info.resources(Lilly.Lifecycle), &(resource_name(&1) == name))
  end

  @spec resource_name(module()) :: String.t()
  def resource_name(resource), do: resource |> Module.split() |> List.last()

  # Closed resource identity atoms for diagnostic events; the bare resource
  # name string has no corresponding atom and must never be atomized at runtime.
  @spec resource_event(module()) :: atom()
  def resource_event(resource) do
    case resource_name(resource) do
      "BackupSnapshot" -> :backup_snapshot
      "SnapshotPointer" -> :snapshot_pointer
      "Resize" -> :resize
      "Execution" -> :execution
      "GuestTrust" -> :guest_trust
      "Provisioning" -> :provisioning
      "ImageTemplate" -> :image_template
      "WorkspaceSource" -> :workspace_source
      "Dataset" -> :dataset
      "SnapshotSet" -> :snapshot_set
      "Import" -> :import
      "CloneCopy" -> :clone_copy
      "Permit" -> :permit
    end
  end

  defp action(resource, type, state) do
    name = if(type == :create, do: "initialize_", else: "mark_") <> Atom.to_string(state)

    case Enum.find(Ash.Resource.Info.actions(resource), &(Atom.to_string(&1.name) == name)) do
      nil -> :invalid_transition
      action -> action.name
    end
  end
end
