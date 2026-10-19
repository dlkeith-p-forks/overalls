defmodule Marshall.Accounts.ScimLifecycle do
  @moduledoc "Records the seven-day SCIM retirement deadline without tombstoning early."
  use Ash.Resource.Change

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), map()) :: Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :active) do
      false ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :scim_retirement_deadline,
          DateTime.add(DateTime.utc_now(), 7, :day)
        )

      true ->
        Ash.Changeset.force_change_attribute(changeset, :scim_retirement_deadline, nil)

      _ ->
        changeset
    end
  end
end
