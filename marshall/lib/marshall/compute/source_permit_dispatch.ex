defmodule Marshall.Compute.SourcePermitDispatch do
  @moduledoc "Wake source polling without interpreting job delivery as a physical outcome."
  use Ash.Resource.Change
  # @cc [owner:ghuntley,label:recovery] source-permit-dispatch-hint-only
  # Notifications MUST NOT mutate lease results or reservations. Source polling
  # MUST remain able to recover work after a lost or duplicate notification.
  @impl true
  def change(changeset, _, _) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      request = changeset.data

      # Hints the host to exchange now; its periodic exchange is the backstop.
      Marshall.Control.Hints.notify(:host_commands, request.source_host_id)

      changeset
    end)
  end
end
