defmodule Marshall.Artifacts.UsageReconcileJob do
  @moduledoc "Daily recomputation of storage usage counters from their entries."
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3_600]

  require Marshall.Events
  alias Marshall.Repo

  # @cc [owner:ghuntley,label:capacity;observability] artifact-usage-reconcile
  # Usage counters MUST equal the sum of their scope's entries; drift is
  # corrected under the usage row lock and reported by artifact and namespace.
  @impl true
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    %{rows: rows} =
      Repo.query!("""
      SELECT u.id, u.artifact_id, u.namespace
      FROM artifact_storage_usage AS u
      LEFT JOIN LATERAL (
        SELECT coalesce(sum(e.bytes), 0)::bigint AS bytes, count(*)::bigint AS entries
        FROM artifact_storage_entries AS e
        WHERE e.artifact_id = u.artifact_id AND e.namespace = u.namespace
          AND e.scope_id = u.scope_id
      ) AS actual ON true
      WHERE u.bytes <> actual.bytes OR u.entries <> actual.entries
      LIMIT 1000
      """)

    Enum.each(rows, fn [id, artifact_id, namespace] ->
      Repo.query!(
        """
        UPDATE artifact_storage_usage AS u
        SET bytes = actual.bytes, entries = actual.entries, updated_at = now()
        FROM (
          SELECT coalesce(sum(e.bytes), 0)::bigint AS bytes, count(*)::bigint AS entries
          FROM artifact_storage_usage AS l
          JOIN artifact_storage_entries AS e
            ON e.artifact_id = l.artifact_id AND e.namespace = l.namespace
           AND e.scope_id = l.scope_id
          WHERE l.id = $1
        ) AS actual
        WHERE u.id = $1
        """,
        [id]
      )

      Marshall.Events.emit("artifact.usage_drift",
        artifact_id: Ecto.UUID.load!(artifact_id),
        namespace: String.to_existing_atom(namespace)
      )
    end)

    :ok
  end
end
