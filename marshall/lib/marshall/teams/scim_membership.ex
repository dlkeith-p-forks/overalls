defmodule Marshall.Teams.ScimMembership do
  @moduledoc "Records SCIM membership changes under the hidden service owner."
  use Ash.Resource.Change

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), map()) :: Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    owner =
      Marshall.Accounts.User
      |> Ash.Query.for_read(:internal_lookup, %{},
        actor: Marshall.Authorization.SystemActor.compute()
      )
      |> Ash.Query.filter(email == "scim-service-owner@deleted.invalid")
      |> Ash.read_one!(actor: Marshall.Authorization.SystemActor.compute())

    Ash.Changeset.force_change_attribute(changeset, :recorded_by_id, owner.id)
  end
end
