defmodule Marshall.Android.DisplayTicketsTest do
  use ExUnit.Case, async: true

  alias Marshall.Android.DisplayTickets

  test "malformed and expired-shaped tokens are refused" do
    assert {:error, :invalid_ticket} = DisplayTickets.verify("not-a-ticket")
    assert {:error, :invalid_ticket} = DisplayTickets.verify(nil)
  end

  test "claim matching fences machine, generation and mode" do
    claim = %{machine_id: "machine-1", generation: 4, mode: :viewer}

    assert DisplayTickets.claim_matches?(claim, "machine-1", 4, :viewer)
    refute DisplayTickets.claim_matches?(claim, "machine-2", 4, :viewer)
    refute DisplayTickets.claim_matches?(claim, "machine-1", 5, :viewer)
    refute DisplayTickets.claim_matches?(claim, "machine-1", 4, :controller)
  end
end
