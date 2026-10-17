defmodule Marshall.Compute.RelocationAdvance do
  @moduledoc "Run one coordinator step without holding an Ash relocation row lock first."
  use Ash.Resource.Change
  # @cc [owner:ghuntley,label:concurrency] relocation-job-lock-order
  # The action MUST be nontransactional and its trigger must not prelock the row.
  # The coordinator owns the host-before-VM transaction; errors must retry via Oban.
  @impl true
  def change(changeset, _, _) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Marshall.Compute.RelocationCoordinator.advance(changeset.data.id) do
        {:ok, _} -> changeset
        {:error, _} -> Ash.Changeset.add_error(changeset, "relocation reconciliation failed")
      end
    end)
  end
end
