defmodule Marshall.Scim.TeamRetirement do
  @moduledoc "Starts retirement of native teams when SCIM becomes authoritative."
  alias Marshall.Compute.Ledger
  alias Marshall.Teams.Team
  require Ash.Query
  require Marshall.Events

  @grace_seconds 7 * 24 * 60 * 60

  # @cc [owner:ghuntley,label:security;recovery] scim-enable-native-team-retirement
  # Enabling SCIM MUST mark every active :native team :retiring with a shared
  # seven-day deadline and enqueue its TeamRetirementWorker in the caller's
  # Ledger transaction. Already retiring or SCIM-managed teams are unchanged,
  # so repeated enables are idempotent.
  @spec retire_native_teams!() :: :ok
  def retire_native_teams! do
    deadline = DateTime.add(Ledger.now(), @grace_seconds, :second)

    Team
    |> Ash.Query.filter(management_mode == :native)
    |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
    |> Enum.each(fn team ->
      Ledger.update!(team, :mark_retiring, %{
        management_mode: :retiring,
        scim_retirement_deadline: deadline
      })

      %{"team_id" => team.id}
      |> Marshall.Scim.TeamRetirementWorker.new(scheduled_at: deadline)
      |> Oban.insert!()

      Ledger.after_commit(fn ->
        Marshall.Events.emit("scim.team_retirement_started", team_id: team.id)
      end)
    end)

    :ok
  end
end
