defmodule Marshall.Inference.Retention do
  @moduledoc "Bounded detail and daily-total retention, including content-free detail audit versions."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Inference.{Request, Daily, Totals}
  require Ash.Query
  require Marshall.Events
  @impl true
  def run(_, _, %{actor: %SystemActor{purpose: :compute}}) do
    result =
      Ledger.transaction(fn ->
        now = Ledger.now()
        days = Application.get_env(:marshall, :inference_detail_days, 90)
        aggregate_days = Application.get_env(:marshall, :inference_aggregate_days, 365)
        cutoff = DateTime.add(now, -days * 86_400)

        rows =
          Request
          |> Ash.Query.filter(inserted_at < ^cutoff and expires_at < ^now)
          |> Ash.Query.sort(inserted_at: :asc, id: :asc)
          |> Ash.Query.limit(500)
          |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
          |> Ash.read!(actor: SystemActor.compute())

        Enum.each(rows, fn row ->
          if is_nil(row.completion),
            do: Totals.add!(row, %{"tokens" => %{}, "completeness" => "unknown"})

          Ecto.Adapters.SQL.query!(
            Marshall.Repo,
            "DELETE FROM inference_requests_versions WHERE version_source_id = $1",
            [Ecto.UUID.dump!(row.id)],
            log: false
          )

          Ledger.archive!(row, :purge)
        end)

        daily_cutoff = Date.add(DateTime.to_date(now), -aggregate_days)

        daily =
          Daily
          |> Ash.Query.filter(day < ^daily_cutoff)
          |> Ash.Query.sort(day: :asc, id: :asc)
          |> Ash.Query.limit(500)
          |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
          |> Ash.read!(actor: SystemActor.compute())

        Enum.each(daily, &Ledger.archive!(&1, :purge))

        if length(rows) == 500 or length(daily) == 500,
          do:
            AshOban.schedule(Request, :prune,
              action_arguments: %{continuation: Ash.UUID.generate()}
            )

        length(rows) + length(daily)
      end)

    with {:ok, count} <- result do
      unless Marshall.Repo.in_transaction?(),
        do: Marshall.Events.emit("inference.retention_deleted", deleted_count: count)
    end

    result
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}
end
