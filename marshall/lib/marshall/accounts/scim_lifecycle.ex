defmodule Marshall.Accounts.ScimLifecycle do
  @moduledoc "Records the seven-day SCIM retirement deadline without tombstoning early."
  use Ash.Resource.Change

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), map()) :: Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    # Tombstoned identities are immutable.  SCIM providers frequently retry
    # stale PATCH/PUT requests after a DELETE; accepting those writes would
    # resurrect credentials or the mailbox identity.
    if changeset.data.deleted_at != nil do
      Ash.Changeset.add_error(changeset,
        field: :active,
        message: "identity is permanently retired"
      )
    else
      change_active(changeset)
    end
  end

  defp change_active(changeset) do
    case Ash.Changeset.get_attribute(changeset, :active) do
      false ->
        changeset =
          Ash.Changeset.force_change_attribute(
            changeset,
            :scim_retirement_deadline,
            DateTime.add(DateTime.utc_now(), 7, :day)
          )

        Ash.Changeset.after_action(changeset, fn _changeset, _record ->
          Marshall.Scim.RetirementWorker.new(%{}, unique: [period: 60, keys: [:worker]])
          |> Oban.insert()

          {:ok, _record}
        end)

      true ->
        Ash.Changeset.force_change_attribute(changeset, :scim_retirement_deadline, nil)

      _ ->
        changeset
    end
  end
end
