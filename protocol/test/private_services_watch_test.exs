defmodule OverallsProtocol.PrivateServicesWatchTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias OverallsProtocol.PrivateServices

  @purposes [:services, :ssh_roster, :ssh_host_certificate]
  @uuid "11111111-1111-4111-8111-111111111111"
  @binding %{
    "host_id" => @uuid,
    "vm_id" => @uuid,
    "placement_id" => @uuid,
    "execution_epoch" => 1
  }
  @roster Map.merge(@binding, %{"generation" => 2, "operation_id" => @uuid})

  property "requests round-trip exactly for canonical addresses and fixed purposes" do
    check all(
            octets <- list_of(integer(0..255), length: 4),
            purpose <- member_of(@purposes)
          ) do
      address = Enum.join(octets, ".")
      request = PrivateServices.watch_request(address, purpose)
      assert PrivateServices.decode_watch_request(request) == {:ok, address, purpose}
    end
  end

  property "hostile requests are refused" do
    check all(
            address <-
              member_of(["010.0.0.1", "1.2.3", "1.2.3.4.5", "256.1.1.1", "::1", " 1.2.3.4", ""]),
            purpose <- member_of(["services", "roster", "SSH_ROSTER", "", "ssh_roster "]),
            extra <- boolean(),
            version <- member_of([1, 2, 3, 4, "3"])
          ) do
      request = %{"version" => version, "address" => address, "purpose" => purpose}
      request = if extra, do: Map.put(request, "watch", true), else: request
      assert PrivateServices.decode_watch_request(request) == {:error, :invalid_request}
    end
  end

  test "grants validate per purpose and revocation is one fixed frame" do
    assert {:ok, @binding} =
             PrivateServices.decode_grant(PrivateServices.grant(:services, @binding), :services)

    for purpose <- [:ssh_roster, :ssh_host_certificate] do
      assert {:ok, @roster} =
               PrivateServices.decode_grant(PrivateServices.grant(purpose, @roster), purpose)

      # A services binding never satisfies a roster purpose, nor vice versa.
      assert {:error, :invalid_grant} =
               PrivateServices.decode_grant(PrivateServices.grant(purpose, @binding), purpose)
    end

    assert {:error, :invalid_grant} =
             PrivateServices.decode_grant(PrivateServices.grant(:ssh_roster, @roster), :services)

    assert {:error, :invalid_grant} =
             PrivateServices.decode_grant(
               Map.put(PrivateServices.grant(:services, @binding), "x", 1),
               :services
             )

    assert PrivateServices.revocation?(PrivateServices.revocation())
    refute PrivateServices.revocation?(%{"version" => 3, "revoked" => false})
  end
end
