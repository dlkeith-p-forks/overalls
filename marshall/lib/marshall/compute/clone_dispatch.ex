defmodule Marshall.Compute.CloneDispatch do
  @moduledoc "AshOban entry point; database state, not job delivery, owns clone progress."
  use Ash.Resource.Change

  # @cc [owner:ghuntley,label:recovery] clone-job-reconciles-persisted-authority
  # Duplicate jobs MUST re-read the request and its source queue before effects.
  # Worker failure MUST leave unfinished requests eligible for scheduled repair.
  @impl true
  def change(changeset, _options, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Marshall.Compute.CloneCoordinator.advance(changeset.data.id) do
        {:ok, _} ->
          changeset

        {:error, reason} ->
          Ash.Changeset.add_error(changeset, Marshall.Compute.Error.exception(reason: reason))
      end
    end)
  end
end
