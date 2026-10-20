defmodule Marshall.Teams.ScimCreate do
  @moduledoc "Binds SCIM-created teams to the hidden service owner."
  use Ash.Resource.Change
  alias Marshall.Compute.Ledger
  alias Marshall.Teams.{ServiceOwner, TeamMember}
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;product] scim-team-service-owner
  # A SCIM-created team MUST be :scim_managed, created by the service owner and
  # gain exactly one owner membership for the service owner in the same
  # transaction, with payload-free team receipts. Its event follows the commit.
  @impl true
  @spec change(Ash.Changeset.t(), keyword(), map()) :: Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    case ServiceOwner.get() do
      nil ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Changes.InvalidChanges.exception(message: "SCIM service owner is unavailable")
        )

      owner ->
        changeset
        |> Ash.Changeset.force_change_attribute(:created_by_id, owner.id)
        |> Ash.Changeset.force_change_attribute(:management_mode, :scim_managed)
        |> Ash.Changeset.after_action(fn _changeset, team ->
          Ledger.create!(TeamMember, :record, %{
            team_id: team.id,
            user_id: owner.id,
            role: :owner,
            recorded_by_id: owner.id
          })

          receipt!(owner.id, team.id, :team_create)
          receipt!(owner.id, team.id, :team_membership_change)

          Ledger.after_commit(fn ->
            Marshall.Events.emit("team.membership_changed",
              team_id: team.id,
              user_id: owner.id,
              actor_id: owner.id,
              operation_status: :created
            )
          end)

          {:ok, team}
        end)
    end
  end

  defp receipt!(actor_id, target_id, kind) do
    Ledger.create!(Marshall.Accounts.AdminEvent, :record, %{
      actor_id: actor_id,
      target_id: target_id,
      kind: kind
    })
  end
end
