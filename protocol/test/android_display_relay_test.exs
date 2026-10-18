defmodule OverallsProtocol.AndroidDisplayRelayTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.AndroidDisplayRelay

  test "valid display prefaces round trip" do
    assert {:ok, encoded} = AndroidDisplayRelay.encode("signed-ticket", 7, :controller)

    assert {:ok, %{ticket: "signed-ticket", generation: 7, mode: :controller}} =
             AndroidDisplayRelay.decode(encoded)
  end

  test "unknown fields and invalid authority are refused" do
    assert {:error, :invalid_message} =
             AndroidDisplayRelay.decode(
               ~s({"version":1,"ticket":"x","generation":1,"mode":"viewer","extra":true})
             )

    assert {:error, :invalid_message} = AndroidDisplayRelay.encode("", 1, :viewer)
    assert {:error, :invalid_message} = AndroidDisplayRelay.encode("x", 0, :viewer)
    assert {:error, :invalid_message} = AndroidDisplayRelay.encode("x", 1, :writer)
  end
end
