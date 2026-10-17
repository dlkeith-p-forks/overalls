defmodule Marshall.Compute.ProbeDispatch do
  @moduledoc "Wake probe polling without interpreting job delivery as a physical outcome."
  use Ash.Resource.Change
  # @cc [owner:ghuntley,label:recovery] probe-dispatch-hint-only
  # Notifications MUST NOT mutate lease results or reservations. Probe polling
  # MUST remain able to recover work after a lost or duplicate notification.
  @impl true
  def change(changeset, _, _) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      request = changeset.data

      # Hints the host to exchange now; its periodic exchange is the backstop.
      Marshall.Control.Hints.notify(:host_commands, request.host_id)

      changeset
    end)
  end
end
