defmodule Marshall.Threads.Changes.SyncGeneration do
  @moduledoc "Projects a committed thread transition onto its current generation row."
  use Ash.Resource.Change

  # @cc [owner:ghuntley,label:durability;recovery] thread-generation-sync-in-transition
  # The current generation MUST mirror the thread status inside the transition's
  # transaction. Callers MUST NOT need to remember a separate sync step; a
  # transition that opens a new machine key leaves syncing to `Generation.open_next!/1`.
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, thread ->
      _generation = Marshall.Threads.Generation.sync!(thread)
      {:ok, thread}
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
