defmodule Marshall.SSH.Retention do
  @moduledoc "Bounded AshOban cleanup of expired connection and approval records."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.SSH.{Approval, Session}
  require Ash.Query
  @batch 500

  # @cc [owner:ghuntley,label:recovery;security] ssh-expired-session-retention
  # Cleanup MUST delete at most 500 sessions expired for seven days per transaction,
  # deleting their approvals first. It MUST NOT delete keys or command receipts.
  # A full batch MUST schedule a durable continuation in the same transaction.
  @impl true
  def run(_, _, _) do
    Ledger.transaction(fn ->
      cutoff = DateTime.add(Ledger.now(), -7 * 86_400)

      sessions =
        Session
        |> Ash.Query.filter(expires_at < ^cutoff)
        |> Ash.Query.sort(expires_at: :asc, id: :asc)
        |> Ash.Query.limit(@batch)
        |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
        |> Ash.read!(actor: SystemActor.compute())

      for session <- sessions do
        for approval <- Ledger.read!(Approval, session_id: session.id),
            do: Ledger.archive!(approval, :purge)

        Ledger.archive!(session, :purge)
      end

      count = length(sessions)

      if count == @batch do
        AshOban.schedule(Session, :prune, action_arguments: %{continuation: Ash.UUID.generate()})
      end

      count
    end)
    |> Marshall.SSH.Error.result()
  end
end
