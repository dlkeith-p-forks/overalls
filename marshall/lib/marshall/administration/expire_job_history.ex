defmodule Marshall.Administration.ExpireJobHistory do
  @moduledoc "Indexed, bounded physical cleanup; history reads enforce expiry independently."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Administration.JobSnapshot
  require Marshall.Events

  # @cc [owner:ghuntley,label:recovery;capacity] job-history-retention-batches
  # Cleanup MUST delete at most 1000 expired rows per table per transaction and
  # enqueue a continuation atomically when a batch fills. Active snapshots and
  # unexpired events MUST remain, independently of raw Oban pruning.
  @impl true
  def run(_, _, _) do
    result =
      Marshall.Repo.transaction(fn ->
        cutoff = Marshall.Compute.Ledger.now()

        counts =
          for table <- ["admin_job_events", "admin_job_snapshots"] do
            %{num_rows: count} =
              Ecto.Adapters.SQL.query!(
                Marshall.Repo,
                """
                WITH expired AS (
                  SELECT id FROM #{table} WHERE expires_at <= $1
                  ORDER BY expires_at, id LIMIT 1000 FOR UPDATE SKIP LOCKED
                ) DELETE FROM #{table} s USING expired e WHERE s.id = e.id
                """,
                [cutoff],
                log: false
              )

            count
          end

        if 1000 in counts do
          AshOban.schedule(JobSnapshot, :expire,
            action_arguments: %{continuation: Ash.UUID.generate()}
          )
        end

        Enum.sum(counts)
      end)

    with {:ok, count} <- result do
      unless Marshall.Repo.in_transaction?(),
        do: Marshall.Events.emit("admin.job_history_deleted", deleted_count: count)
    end

    result
  end
end
