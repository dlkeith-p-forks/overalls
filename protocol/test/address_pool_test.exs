defmodule OverallsProtocol.AddressPoolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias OverallsProtocol.AddressPool

  property "valid slots map injectively into their profile's /16" do
    check all(slots <- uniq_list_of(integer(2..65534), max_length: 100)) do
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
  end

  property "paired addresses share a slot and never overlap any profile" do
    check all(slots <- uniq_list_of(integer(2..65534), min_length: 1, max_length: 100)) do
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
  end

  test "network, gateway, broadcast and out-of-range slots are reserved" do
    for slot <- [-1, 0, 1, 65535, 65536], profile <- [:customer, :standard, :oss, :inception] do
      assert {:error, :invalid_address} = AddressPool.address(profile, slot)
      assert {:error, :invalid_address} = AddressPool.addresses(profile, slot)
    end

    assert {:error, :invalid_address} = AddressPool.address(:unknown, 2)
  end
end
