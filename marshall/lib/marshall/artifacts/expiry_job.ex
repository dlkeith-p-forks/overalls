defmodule Marshall.Artifacts.ExpiryJob do
  @moduledoc """
  Minute cron: expires view tickets and staged publishes, deletes retired
  tickets after a day and artifact audit rows after ninety days.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 50]

  import Ecto.Query
  require Ash.Query
  alias Marshall.Artifacts.{PublishRequest, Staging, ViewTicket}
  alias Marshall.Compute.Ledger
  alias Marshall.Repo

  @batch 500

  # @cc [owner:ghuntley,label:security;capacity] artifact-expiry
  # Issued tickets past expiry MUST become `expired`; staging requests past
  # expiry MUST become `expired`, release their chunks and resume the parent
  # command so it fails closed. Retired tickets are deleted after one day and
  # artifact audit rows after their ninety-day expiry.
  @impl true
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    now = Ledger.now()

    ViewTicket
    |> Ash.Query.filter(state == :issued and expires_at <= ^now)
    |> Ash.Query.limit(@batch)
    |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
    |> Enum.each(fn ticket ->
      Ledger.transaction(
        fn ->
          case Ledger.lock!(ViewTicket, ticket.id) do
            %ViewTicket{state: :issued} = locked -> Ledger.update!(locked, :expire, %{})
            _ -> :ok
          end
        end,
        {:system, nil}
      )
    end)

    PublishRequest
    |> Ash.Query.filter(state == :staging and expires_at <= ^now)
    |> Ash.Query.limit(@batch)
    |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
    |> Enum.each(fn staged ->
      Ledger.transaction(
        fn ->
          case Ledger.lock!(PublishRequest, staged.id) do
            %PublishRequest{state: :staging} = locked ->
              Ledger.update!(locked, :expire, %{})
              Staging.release!(locked.id)

              %{"command_id" => locked.command_id}
              |> Marshall.Agents.ServerToolJob.new()
              |> Oban.insert!()

            _ ->
              :ok
          end
        end,
        {:system, nil}
      )
    end)

    retired = DateTime.add(now, -1, :day)

    Repo.delete_all(
      from(t in "artifact_view_tickets",
        where:
          t.id in subquery(
            from(i in "artifact_view_tickets",
              where: i.state in ["expired", "revoked"] and i.expires_at < ^retired,
              select: i.id,
              limit: @batch
            )
          )
      )
    )

    Repo.delete_all(
      from(e in "artifact_audit_events",
        where:
          e.id in subquery(
            from(i in "artifact_audit_events",
              where: i.expires_at < ^now,
              select: i.id,
              limit: @batch
            )
          )
      )
    )

    :ok
  end
end
