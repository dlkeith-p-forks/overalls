defmodule Lilly.Network.AndroidDisplayTest do
  use ExUnit.Case, async: true
  alias Lilly.Network.{AndroidDisplay, Guest}

  test "derives fixed display target for the current generation" do
    assert {:ok, guest} = Guest.new("11111111-1111-4111-8111-111111111111", :standard, 7)

    assert {:ok, target} =
             AndroidDisplay.target(guest, %{android_display: true, generation: 9}, 9)

    assert target.address == guest.address
    assert target.port == 5900
    assert target.generation == 9
  end

  test "rejects stale generations and absent capability" do
    assert {:ok, guest} = Guest.new("11111111-1111-4111-8111-111111111111", :standard, 7)

    assert {:error, :display_unavailable} =
             AndroidDisplay.target(guest, %{android_display: true, generation: 8}, 9)

    assert {:error, :display_unavailable} =
             AndroidDisplay.target(guest, %{android_display: false, generation: 9}, 9)
  end
end
