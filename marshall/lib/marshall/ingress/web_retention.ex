defmodule Marshall.Ingress.WebRetention do
  @moduledoc "Bounded browser and web-stream cleanup with audit history retained."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.{Error, WebCredential, WebLogin, WebStream}
  require Ash.Query

  # @cc [owner:ghuntley,label:recovery;concurrency] ingress-web-retention
  # Cleanup MUST delete at most 500 records per transaction, only after seven
  # days of expiry. Streams precede credentials; referenced credentials MUST
  # remain. Audits and service/VM identities MUST remain. A full batch schedules
  # continuation atomically, and locked rows are skipped rather than blocking.
  @impl true
  def run(_, _, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn ->
      cutoff = DateTime.add(Ledger.now(), -7 * 86_400)
      streams = purge(WebStream, cutoff, 200)
      credentials = WebCredential |> Ash.Query.filter(not exists(streams, true))
      credentials = purge(credentials, cutoff, 150)
      logins = purge(WebLogin, cutoff, 150)

      if streams == 200 or credentials == 150 or logins == 150 do
        AshOban.schedule(WebStream, :prune,
          action_arguments: %{continuation: Ash.UUID.generate()}
        )
      end

      streams + credentials + logins
    end)
    |> Error.result()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  defp purge(query, cutoff, limit) do
    records =
      query
      |> Ash.Query.filter(expires_at < ^cutoff)
      |> Ash.Query.sort(expires_at: :asc, id: :asc)
      |> Ash.Query.limit(limit)
      |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
      |> Ash.read!(actor: SystemActor.compute())

    Enum.each(records, &Ledger.archive!(&1, :purge))
    length(records)
  end
end
