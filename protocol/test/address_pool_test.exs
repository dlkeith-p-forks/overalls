defmodule OverallsProtocol.AddressPoolTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.AddressPool

  property "valid slots map injectively into their profile's /16",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_945_242_695 do
    slots = draw("slots", uniq_list_of(integer(2..65534), min: 0, max: 100))

    addresses =
      for {profile, octet} <- [customer: 10, standard: 20, oss: 30, inception: 40],
          slot <- slots do
        {:ok, address} = AddressPool.address(profile, slot)

        assert {:ok, {10, ^octet, high, low}} =
                 :inet.parse_ipv4_address(String.to_charlist(address))

        assert high * 256 + low == slot
        address
      end

    assert length(Enum.uniq(addresses)) == length(addresses)
  end

  property "paired addresses share a slot and never overlap any profile",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 358_681_660 do
    slots = draw("slots", uniq_list_of(integer(2..65534), min: 1, max: 100))

    addresses =
      for slot <- slots, profile <- [:customer, :standard, :oss, :inception] do
        assert {:ok, [control | rest] = addresses} = AddressPool.addresses(profile, slot)
        assert {:ok, ^control} = AddressPool.address(profile, slot)

        if profile == :inception do
          assert [audi] = rest
          assert {:ok, {10, 41, high, low}} = :inet.parse_ipv4_address(String.to_charlist(audi))
          assert high * 256 + low == slot
        else
          assert rest == []
        end

        addresses
      end
      |> List.flatten()

    assert length(Enum.uniq(addresses)) == length(addresses)
  end

  test "network, gateway, broadcast and out-of-range slots are reserved" do
    for slot <- [-1, 0, 1, 65535, 65536], profile <- [:customer, :standard, :oss, :inception] do
      assert {:error, :invalid_address} = AddressPool.address(profile, slot)
      assert {:error, :invalid_address} = AddressPool.addresses(profile, slot)
    end

    assert {:error, :invalid_address} = AddressPool.address(:unknown, 2)
  end
end
