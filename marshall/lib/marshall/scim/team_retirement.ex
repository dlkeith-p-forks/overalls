defmodule Marshall.Scim.TeamRetirement do
  @moduledoc "Archives native teams when SCIM becomes authoritative."
  alias Marshall.Compute.Ledger
  alias Marshall.Teams.Team
  require Ash.Query
  require Marshall.Events

  @spec retire_native_teams!() :: :ok
  def retire_native_teams! do
    Team
    |> Ash.Query.filter(is_nil(archived_at) and management_mode == :native)
    |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
    |> Enum.each(fn team ->
      Ledger.update!(team, :mark_retiring, %{management_mode: :retiring})
      Ledger.archive!(team, :archive)

      Ledger.after_commit(fn ->
        Marshall.Events.emit("scim.team_retirement_started", team_id: team.id)
      end)
    end)

    :ok
  end
end
