defmodule Marshall.Compute.Dispatch do
  @moduledoc """
  Hints the placement's host to exchange now for a durable pending operation.

  The operation remains pending until a host acknowledgement is reconciled.
  The `host_commands` control hint (ADR-0142) only lowers latency: Lilly's
  periodic exchange still discovers pending operations, and the AshOban
  scheduler repeats notification after lost hints or node restarts.
  """
  use Ash.Resource.Change
  alias Marshall.Compute.{Ledger, WorkloadPlacement}

  # @cc [owner:ghuntley,label:recovery] dispatch-is-only-a-hint
  # Dispatch notification MUST NOT acknowledge or complete an operation. The
  # durable pending operation MUST remain discoverable after a lost control hint
  # or duplicate job execution.
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      operation = changeset.data
      [placement] = Ledger.read!(WorkloadPlacement, id: operation.placement_id)

      # Hints the host to exchange now; its periodic exchange is the backstop.
      Marshall.Control.Hints.notify(:host_commands, placement.host_id)

      changeset
    end)
  end
end
