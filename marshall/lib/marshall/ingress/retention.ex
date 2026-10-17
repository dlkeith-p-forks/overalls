defmodule Marshall.Ingress.Retention do
  @moduledoc "Bounded durable cleanup; expired sessions never renew or become live again."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.Session
  require Ash.Query

  # @cc [owner:ghuntley,label:recovery] ingress-session-retention
  # Each cleanup transaction MUST purge at most 500 sessions expired for seven
  # days, retaining their audit versions. A full batch MUST schedule continuation
  # atomically. No key, endpoint or service identity may be deleted here.
  @impl true
  def run(_, _, %{actor: %SystemActor{purpose: :compute}}) do
    Ledger.transaction(fn ->
      cutoff = DateTime.add(Ledger.now(), -7 * 86_400)

      sessions =
        Session
        |> Ash.Query.filter(expires_at < ^cutoff)
        |> Ash.Query.sort(expires_at: :asc, id: :asc)
        |> Ash.Query.limit(500)
        |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
        |> Ash.read!(actor: SystemActor.compute())

      Enum.each(sessions, &Ledger.archive!(&1, :purge))

      if length(sessions) == 500,
        do:
          AshOban.schedule(Session, :prune,
            action_arguments: %{continuation: Ash.UUID.generate()}
          )

      length(sessions)
    end)
    |> Marshall.Ingress.Error.result()
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}
end
