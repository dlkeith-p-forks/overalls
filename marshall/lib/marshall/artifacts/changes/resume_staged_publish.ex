defmodule Marshall.Artifacts.Changes.ResumeStagedPublish do
  @moduledoc """
  When an `artifact_stage` command reaches a terminal status by any path
  (result, refusal, lease retirement), enqueue its parent publish job in the
  same transaction.
  """
  use Ash.Resource.Change

  @terminal [:completed, :failed, :uncertain, :cancelled]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, result ->
      if result.tool == :artifact_stage and result.status in @terminal and
           changeset.data.status not in @terminal,
         do: Marshall.Artifacts.Staging.stage_finished_locked!(result)

      {:ok, result}
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
