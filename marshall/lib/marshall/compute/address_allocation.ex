defmodule Marshall.Compute.AddressAllocation do
  @moduledoc "Profile allocation under the admission transaction. No release before physical cleanup."
  alias Marshall.Compute.Ledger

  # @cc [owner:ghuntley,label:concurrency] addresses-profile-reservation-lock
  # The caller MUST keep the profile lock through address reservation in the same
  # transaction and acquire it before host locks. Allocation MUST use an unclaimed
  # slot in 2..65534 for that profile; exhaustion MUST fail rather than reuse an
  # active address or borrow another profile's pool.
  @doc "Trusted coordinator: requires a transaction; take this lock before host locks."
  @spec next_slot!(OverallsProtocol.AddressPool.profile()) :: pos_integer()
  def next_slot!(profile) when profile in [:customer, :standard, :oss, :inception] do
    profile = Atom.to_string(profile)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["address-pool:" <> profile],
      log: false
    )

    # Bounded by the fixed /16 pool. The database uniqueness constraint is a
    # second guard. Confirmed deletion only removes an active allocation, so it
    # needs no profile lock: MVCC may conservatively defer reuse until commit.
    case Ecto.Adapters.SQL.query!(
           Marshall.Repo,
           """
           SELECT candidate FROM generate_series(2, 65534) AS candidate
           WHERE NOT EXISTS (
             SELECT 1 FROM compute_network_addresses WHERE profile = $1 AND slot = candidate AND archived_at IS NULL
           ) ORDER BY candidate LIMIT 1
           """,
           [profile],
           log: false
         ) do
      %{rows: [[slot]]} -> slot
      %{rows: []} -> Ledger.rollback(:address_pool_exhausted)
    end
  end
end
