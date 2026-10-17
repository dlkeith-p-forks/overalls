defmodule Marshall.Compute.DestinationReceiveDispatch do
  @moduledoc "Durable source receipt notification; destination polling remains authoritative."
  use Ash.Resource.Change
  # @cc [owner:ghuntley,label:recovery] receive-notification-is-only-a-hint
  # Dispatch MUST only wake the immutable destination's control poll. Lost hints
  # or job exhaustion MUST NOT lose the retained request or establish receipt.
  @impl true
  def change(changeset, _, _) do
    Ash.Changeset.after_action(changeset, fn _, request ->
      [relocation] =
        Marshall.Compute.Ledger.read!(Marshall.Compute.Relocation, id: request.relocation_id)

      # Hints the host to exchange now; its periodic exchange is the backstop.
      Marshall.Control.Hints.notify(:host_commands, relocation.destination_host_id)

      {:ok, request}
    end)
  end
end
