defmodule Marshall.Notifications.Reconciler do
  @moduledoc """
  Recovers deliveries whose worker was lost (ADR-0225).

  Every minute, open deliveries that are stuck in `sending`, or queued or
  waiting without a live job, are given a job again; the worker drops expired
  rows and resends the rest under the same delivery id.
  """
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Notifications.{Delivery, DeliveryWorker}
  require Ash.Query

  @stuck_seconds 120
  @batch 200

  @doc "Seconds after which a sending attempt is considered lost."
  @spec stuck_seconds() :: pos_integer()
  def stuck_seconds, do: @stuck_seconds

  # @cc [owner:ghuntley,label:recovery] notification-stuck-sending-reconciled
  # A delivery stuck in sending beyond the attempt timeout, or open without a
  # live Oban job, MUST be re-enqueued; the unique worker key prevents a second
  # concurrent sender for the same delivery.
  @impl true
  def run(_input, _options, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn ->
      now = Ledger.now()
      stuck = DateTime.add(now, -@stuck_seconds, :second)

      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          """
          SELECT d.id FROM notification_deliveries d
          WHERE (d.state = 'sending' AND d.sending_started_at < $1)
             OR (d.state IN ('queued', 'retry_wait') AND d.updated_at < $1
                 AND NOT EXISTS (
                   SELECT 1 FROM oban_jobs j
                   WHERE j.worker = $3
                     AND j.args->>'delivery_id' = d.id::text
                     AND j.state IN ('available', 'scheduled', 'executing', 'retryable')))
          ORDER BY d.updated_at, d.id
          LIMIT $2
          """,
          [stuck, @batch, inspect(DeliveryWorker)],
          log: false
        )

      Enum.each(rows, fn [id] ->
        %{delivery_id: Ecto.UUID.cast!(id)} |> DeliveryWorker.new() |> Oban.insert!()
      end)

      # Rows whose worker cannot run before expiry (for example an orphaned
      # executing job) still reach a terminal state.
      expired =
        Delivery
        |> Ash.Query.filter(state in [:queued, :sending, :retry_wait] and expires_at < ^stuck)
        |> Ash.Query.sort(expires_at: :asc, id: :asc)
        |> Ash.Query.limit(@batch)
        |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
        |> Ash.read!(actor: SystemActor.compute())

      Enum.each(expired, fn delivery ->
        Ledger.update!(delivery, :drop, %{drop_reason: :expired, finished_at: now})
      end)

      length(rows) + length(expired)
    end)
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}
end
