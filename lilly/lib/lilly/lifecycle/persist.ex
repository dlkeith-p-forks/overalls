defmodule Lilly.Lifecycle.Persist do
  @moduledoc "Manual Ash publication preserving the native lock-owner durability boundary."
  use Ash.Resource.ManualCreate
  use Ash.Resource.ManualUpdate
  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.Lifecycle.Journal

  @impl Ash.Resource.ManualCreate
  def create(changeset, _, _), do: persist(changeset)

  @impl Ash.Resource.ManualUpdate
  def update(changeset, _, _), do: persist(changeset)

  # @cc [owner:ghuntley,label:recovery;durability] local-state-publication-atomic
  # Publication MUST recheck the loaded revision under the OS lock and atomically
  # persist the next state and revision. Diagnostic delivery MUST NOT determine
  # publication success; uncertain state writes MUST fail without confirmation.
  defp persist(changeset) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         true <- Lock.held?(port),
         {:ok, next} <- Ash.Changeset.apply_attributes(changeset),
         {:ok, current} <- Journal.load(changeset.resource, next.directory, next.filename),
         true <- fresh?(changeset, current),
         true <- changeset.resource.valid_payload?(next.payload),
         true <- changeset.resource.valid_transition?(current && current.payload, next.payload),
         true <- next.revision < 9_223_372_036_854_775_807 do
      revision = next.revision + 1

      event = %{
        "id" => Ash.UUID.generate(),
        "sequence" => revision,
        "action" => Atom.to_string(changeset.action.name),
        "previous_state" => if(current, do: Atom.to_string(current.state)),
        "next_state" => Atom.to_string(next.state),
        "occurred_at" => System.system_time(:microsecond)
      }

      event = Map.merge(event, correlation(next.payload))
      next = %{next | revision: revision}

      metadata = %{
        "version" => 2,
        "resource" => Journal.resource_name(changeset.resource),
        "id" => next.id,
        "state" => Atom.to_string(next.state),
        "revision" => revision
      }

      bytes = JSON.encode!(Map.put(next.payload, "_lifecycle", metadata))

      with true <- byte_size(bytes) <= 65_536,
           {:ok, _, _} <- Journal.envelope(bytes),
           :ok <- PrivateFiles.write(next.directory, next.filename, bytes) do
        committed(event, metadata, changeset.resource)

        {:ok, next}
      else
        _ -> {:error, "lifecycle_publication_unconfirmed"}
      end
    else
      _ -> {:error, "lifecycle_publication_unconfirmed"}
    end
  end

  defp fresh?(%{action_type: :create}, nil), do: true

  defp fresh?(%{action_type: :update, data: previous}, current) when not is_nil(current),
    do: previous == current

  defp fresh?(_, _), do: false

  @spec correlation(map()) :: %{String.t() => String.t()}
  defp correlation(payload) do
    binding = payload["binding"] || get_in(payload, ["source", "binding"]) || payload

    values = %{
      "host_id" => binding["host_id"] || get_in(binding, ["destination", "host_id"]),
      "pool_id" => payload["pool_id"],
      "placement_id" =>
        binding["placement_id"] || get_in(binding, ["spec", "id"]) ||
          get_in(binding, ["destination", "placement_id"]),
      "workflow_id" => binding["relocation_id"] || binding["clone_id"]
    }

    Map.filter(values, fn {_key, value} -> OverallsProtocol.uuid?(value) end)
  end

  # @cc [owner:ghuntley,label:observability;durability;security] lifecycle-diagnostic-after-fsync
  # Reviewed diagnostic IDs, state names and persisted times MUST be emitted
  # only after state fsync and the native writer releases. A refused collector MUST NOT turn committed state
  # into a failed transition. Correlations MUST come only from validated UUIDs.
  @spec committed(map(), map(), module()) :: :ok
  def committed(event, metadata, resource) do
    resource = Journal.resource_event(resource)

    diagnostic = %{
      event_id: event["id"],
      resource_id: metadata["id"],
      resource_type: resource,
      action: String.to_existing_atom(event["action"]),
      next_state: String.to_existing_atom(event["next_state"]),
      revision: metadata["revision"],
      occurred_at: event["occurred_at"]
    }

    diagnostic =
      Enum.reduce([:host_id, :pool_id, :placement_id, :workflow_id], diagnostic, fn key, result ->
        case event[Atom.to_string(key)] do
          value when is_binary(value) ->
            if OverallsProtocol.uuid?(value), do: Map.put(result, key, value), else: result

          _ ->
            result
        end
      end)

    diagnostic =
      if previous = event["previous_state"],
        do: Map.put(diagnostic, :previous_state, String.to_existing_atom(previous)),
        else: diagnostic

    Lilly.Lifecycle.PublicationDiagnostics.defer(diagnostic)
    :ok
  end
end
