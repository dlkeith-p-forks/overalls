defmodule Marshall.Artifacts.PurgeJob do
  @moduledoc "Deletes a deleting artifact's content in bounded batches, then leaves a tombstone."
  use Oban.Worker,
    queue: :artifacts,
    max_attempts: 20,
    unique: [
      period: :infinity,
      keys: [:artifact_id],
      states: [:available, :scheduled, :retryable]
    ]

  import Ecto.Query
  require Marshall.Events
  alias Marshall.Artifacts.{Artifact, Audit}
  alias Marshall.Compute.Ledger
  alias Marshall.Repo

  @batch 1_000

  # Content tables in deletion order; versions last so files go first.
  @tables ~w(artifact_storage_entries artifact_storage_usage artifact_view_tickets
             artifact_version_files artifact_versions)

  # @cc [owner:ghuntley,label:durability;capacity] artifact-purge-batched
  # Purging MUST delete at most 1,000 content rows per transaction, only for an
  # artifact in `deleting`, re-enqueue itself until no content remains, and
  # then move the artifact to `deleted` with one audit row. Blobs are reclaimed
  # separately by the sweep once unreferenced. Re-running is harmless.
  @impl true
  @spec perform(Oban.Job.t()) :: :ok | {:cancel, :invalid_job}
  def perform(%Oban.Job{args: %{"artifact_id" => id}}) when is_binary(id) do
    {:ok, outcome} = Ledger.transaction(fn -> step!(id) end, {:system, nil})

    case outcome do
      :more ->
        %{"artifact_id" => id} |> new(schedule_in: 1) |> Oban.insert!()
        :ok

      _ ->
        :ok
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_job}

  @spec step!(String.t()) :: :more | :done | :skip
  defp step!(id) do
    case Ledger.lock!(Artifact, id) do
      %Artifact{state: :deleting} = artifact ->
        uuid = Ecto.UUID.dump!(id)

        deleted =
          Enum.reduce_while(@tables, 0, fn table, _ ->
            {count, _} =
              Repo.delete_all(
                from(row in table,
                  where:
                    row.id in subquery(
                      from(inner in table,
                        where: inner.artifact_id == ^uuid,
                        select: inner.id,
                        limit: @batch
                      )
                    )
                )
              )

            if count > 0, do: {:halt, count}, else: {:cont, 0}
          end)

        if deleted > 0 do
          :more
        else
          Ledger.update!(artifact, :finish_delete, %{})
          Audit.record!(%{artifact_id: artifact.id, kind: :purged, via: :system})

          Ledger.after_commit(fn ->
            Marshall.Events.emit("artifact.purged", artifact_id: artifact.id, outcome: :completed)
          end)

          :done
        end

      _ ->
        :skip
    end
  end
end
