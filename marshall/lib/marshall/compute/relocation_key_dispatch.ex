defmodule Marshall.Compute.RelocationKeyDispatch do
  @moduledoc "Durable key-preparation notification; polling remains authoritative."
  use Ash.Resource.Change

  # @cc [owner:ghuntley,label:recovery] relocation-key-dispatch-is-hint
  # Dispatch MUST NOT record a key, release capacity or advance execution. The
  # unfinished relocation remains discoverable after lost or duplicate hints.
  @impl true
  def change(changeset, _, _) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      relocation = changeset.data

      # Hints the host to exchange now; its periodic exchange is the backstop.
      Marshall.Control.Hints.notify(:host_commands, relocation.destination_host_id)

      changeset
    end)
  end
end
