defmodule Marshall.Teams.TransferSwap do
  @moduledoc "Atomic ownership swap executed inside the accepted transfer's transaction."
  use Ash.Resource.Change
  alias Marshall.Compute.Ledger
  alias Marshall.Teams.TeamMember

  # @cc [owner:ghuntley,label:security;concurrency] team-transfer-atomic-swap
  # The role swap MUST commit with the accepted transition or not at all:
  # previous owner becomes admin while the target becomes owner, holding the
  # deferred exactly-one-owner database invariant at commit.
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, transfer ->
      from = current_member!(transfer.team_id, transfer.from_user_id)
      to = current_member!(transfer.team_id, transfer.to_user_id)

      Ledger.update!(from, :replace_role, %{role: :admin, recorded_by_id: transfer.from_user_id})
      Ledger.update!(to, :replace_role, %{role: :owner, recorded_by_id: transfer.from_user_id})
      {:ok, transfer}
    end)
  end

  defp current_member!(team_id, user_id) do
    case Ledger.read!(TeamMember, team_id: team_id, user_id: user_id) do
      [member] -> member
      _ -> Ledger.rollback(:transfer_member_missing)
    end
  end
end
