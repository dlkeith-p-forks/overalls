defmodule Marshall.Android.DisplayTicketsTest do
  use ExUnit.Case, async: true

  alias Marshall.Android.DisplayTickets

  test "malformed and expired-shaped tokens are refused" do
    assert {:error, :invalid_ticket} = DisplayTickets.verify("not-a-ticket")
    assert {:error, :invalid_ticket} = DisplayTickets.verify(nil)
  end
end
