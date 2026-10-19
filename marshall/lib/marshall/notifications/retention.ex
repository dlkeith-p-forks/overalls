defmodule Marshall.Notifications.Retention do
  @moduledoc "Prunes terminal deliveries and their audit versions after seven days (ADR-0225)."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Notifications.Delivery
  require Marshall.Events

  @days 7
  @batch 500

  @doc "Retention of terminal deliveries, in days."
  @spec days() :: pos_integer()
  def days, do: @days

  # @cc [owner:ghuntley,label:persistence;recovery] notification-delivery-prune
  # Pruning MUST delete only terminal deliveries finished more than seven days
  # ago, together with their versions, in bounded batches; open deliveries are
  # never pruned whatever their age.
  @impl true
  def run(_input, _options, %{actor: %SystemActor{purpose: :compute}}) do
    result =
      Ledger.transaction(fn ->
        cutoff = DateTime.add(Ledger.now(), -@days * 86_400, :second)

        %{rows: rows} =
          Ecto.Adapters.SQL.query!(
            Marshall.Repo,
            """
            SELECT id FROM notification_deliveries
            WHERE finished_at IS NOT NULL AND finished_at < $1
              AND state IN ('delivered', 'failed_permanent', 'dropped')
            ORDER BY finished_at, id
            LIMIT $2
            FOR UPDATE SKIP LOCKED
            """,
            [cutoff, @batch],
            log: false
          )

        ids = Enum.map(rows, fn [id] -> id end)

        unless ids == [] do
          Ecto.Adapters.SQL.query!(
            Marshall.Repo,
            "DELETE FROM notification_deliveries_versions WHERE version_source_id = ANY($1)",
            [ids],
            log: false
          )

          Ecto.Adapters.SQL.query!(
            Marshall.Repo,
            "DELETE FROM notification_deliveries WHERE id = ANY($1)",
            [ids],
            log: false
          )
        end

        if length(ids) == @batch,
          do:
            AshOban.schedule(Delivery, :prune,
              action_arguments: %{continuation: Ash.UUID.generate()}
            )

        length(ids)
      end)

    with {:ok, count} <- result do
      unless Marshall.Repo.in_transaction?(),
        do: Marshall.Events.emit("notifications.deliveries_pruned", deleted_count: count)
    end

    result
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}
end
