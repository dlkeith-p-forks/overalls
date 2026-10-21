defmodule Marshall.Compute.MessageBoardCleanup do
  @moduledoc "Purges machine-scoped board posts after VM state-machine transitions."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _, _) do
    Ash.Changeset.after_action(changeset, fn _changeset, result ->
      Marshall.MessageBoards.purge_for_state!(result.id, result.desired_state)
      {:ok, result}
    end)
  end

  @impl true
  def atomic(changeset, options, context), do: {:ok, change(changeset, options, context)}
end
