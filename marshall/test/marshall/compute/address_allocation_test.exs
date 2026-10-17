defmodule Marshall.Compute.AddressAllocationTest do
  use Marshall.DataCase, async: false
  alias Marshall.Compute.{AddressAllocation, Ledger}
  alias Marshall.Repo

  test "the bounded allocator finds holes and rejects a full /16 without reusing another profile" do
    # A connection-local temporary relation exercises the production allocator
    # SQL with all 65,533 occupied slots, without inventing thousands of VM rows.
    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TEMP TABLE compute_network_addresses (profile text, slot bigint, archived_at timestamp) ON COMMIT DROP"
    )

    assert {:ok, 2} = Ledger.transaction(fn -> AddressAllocation.next_slot!(:customer) end)

    Ecto.Adapters.SQL.query!(
      Repo,
      "INSERT INTO compute_network_addresses (profile, slot) SELECT 'customer', n FROM generate_series(2, 65534) n WHERE n <> 12345"
    )

    assert {:ok, 12345} = Ledger.transaction(fn -> AddressAllocation.next_slot!(:customer) end)
    assert {:ok, 2} = Ledger.transaction(fn -> AddressAllocation.next_slot!(:oss) end)

    Ecto.Adapters.SQL.query!(
      Repo,
      "INSERT INTO compute_network_addresses (profile, slot) VALUES ('customer', 12345)"
    )

    assert {:error, :address_pool_exhausted} =
             Ledger.transaction(fn -> AddressAllocation.next_slot!(:customer) end)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE compute_network_addresses SET archived_at = clock_timestamp() WHERE profile = 'customer' AND slot = 12345"
    )

    assert {:ok, 12345} = Ledger.transaction(fn -> AddressAllocation.next_slot!(:customer) end)
  end
end
