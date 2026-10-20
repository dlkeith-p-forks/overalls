defmodule Marshall.Teams.ScimRetire do
  @moduledoc "Turns a SCIM Group DELETE into immediate authority revocation and team retirement."
  use Ash.Resource.Change
  alias Marshall.Compute.Ledger
  require Marshall.Events

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), map()) :: Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:management_mode, :retiring)
    |> Ash.Changeset.force_change_attribute(:scim_retirement_deadline, Ledger.now())
    |> Ash.Changeset.after_action(fn _changeset, team ->
      :ok = Marshall.Scim.TeamCleanup.revoke_authority!(team)

      %{"team_id" => team.id}
      |> Marshall.Scim.TeamRetirementWorker.new()
      |> Oban.insert!()

      Ledger.after_commit(fn ->
        Marshall.Events.emit("scim.team_retirement_started", team_id: team.id)
      end)

      {:ok, team}
    end)
  end
end
