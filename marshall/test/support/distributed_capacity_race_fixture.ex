# @cc [owner:ghuntley,label:verification] race-fixture-outcome-peer-boundary
# Physical outcome application MUST run inside the caller peer's host-locked
# transaction over the shared committed database; the fixture adds no state and
# never rewrites or replays outcome shapes.
defmodule Marshall.Compute.DistributedCapacityRaceFixture do
  @moduledoc "Peer-side fixture for capacity-race outcome application."
  alias Marshall.Compute.{Host, Ledger, Outcomes}

  @spec apply_outcome(String.t(), map()) :: {:ok, [String.t()]} | {:error, term()}
  def apply_outcome(host_id, outcome) do
    Ledger.transaction(fn ->
      host = Ledger.lock!(Host, host_id)
      Outcomes.ingest_locked!(host.id, [outcome])
    end)
  end
end
