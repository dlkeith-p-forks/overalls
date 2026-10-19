defmodule Marshall.Teams.ScimCreate do
  @moduledoc "Binds SCIM-created teams to the hidden service owner."
  use Ash.Resource.Change

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), map()) :: Ash.Changeset.t()
  def change(changeset, _opts, %{actor: %{id: actor_id}}),
    do: Ash.Changeset.force_change_attribute(changeset, :created_by_id, actor_id)

  def change(changeset, _opts, _context), do: changeset
end
