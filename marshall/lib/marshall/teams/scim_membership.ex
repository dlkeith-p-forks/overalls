defmodule Marshall.Teams.ScimMembership do
  @moduledoc "Records SCIM membership changes under the hidden service owner."
  use Ash.Resource.Change
  alias Marshall.Compute.Ledger
  alias Marshall.Teams.{ScimManaged, ServiceOwner, Team}
  require Marshall.Events

  @typep operation :: :member | :removed

  # @cc [owner:ghuntley,label:security] scim-membership-member-role
  # SCIM memberships MUST be plain :member rows recorded by the service owner on
  # :scim_managed teams only, and SCIM removal MUST never remove an owner. Each
  # change appends a receipt in its transaction and emits its event after commit.
  @impl true
  @spec change(Ash.Changeset.t(), keyword(), map()) :: Ash.Changeset.t()
  def change(changeset, opts, _context) do
    operation = Keyword.get(opts, :operation, :member)

    case ServiceOwner.get() do
      nil ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Changes.InvalidChanges.exception(message: "SCIM service owner is unavailable")
        )

      owner ->
        changeset
        |> record(operation, owner)
        |> Ash.Changeset.before_action(&require_managed/1)
        |> Ash.Changeset.after_action(fn _changeset, membership ->
          receipt_and_event(membership, owner.id, operation)
          {:ok, membership}
        end)
    end
  end

  @spec record(Ash.Changeset.t(), operation(), Marshall.Accounts.User.t()) :: Ash.Changeset.t()
  defp record(changeset, :member, owner) do
    changeset
    |> Ash.Changeset.force_change_attribute(:recorded_by_id, owner.id)
    |> Ash.Changeset.force_change_attribute(:role, :member)
  end

  defp record(changeset, :removed, _owner), do: changeset

  defp require_managed(changeset) do
    team_id = Ash.Changeset.get_attribute(changeset, :team_id)
    role = Ash.Changeset.get_attribute(changeset, :role)

    case Ledger.read!(Team, id: team_id) do
      [%Team{management_mode: :scim_managed}] when role != :owner ->
        changeset

      _ ->
        Ash.Changeset.add_error(changeset, ScimManaged.refusal())
    end
  end

  @spec receipt_and_event(Marshall.Teams.TeamMember.t(), Ash.UUID.t(), operation()) :: :ok
  defp receipt_and_event(membership, owner_id, operation) do
    Ledger.create!(Marshall.Accounts.AdminEvent, :record, %{
      actor_id: owner_id,
      target_id: membership.team_id,
      kind: :team_membership_change
    })

    Ledger.after_commit(fn ->
      Marshall.Events.emit("team.membership_changed",
        team_id: membership.team_id,
        user_id: membership.user_id,
        actor_id: owner_id,
        operation_status: operation
      )
    end)
  end
end
