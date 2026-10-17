defmodule OverallsProtocol.PrivateServicesWatchTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
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

  property "requests round-trip exactly for canonical addresses and fixed purposes",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_563_821_426 do
    octets = draw("octets", list(integer(0..255), min: 4, max: 4))
    purpose = draw("purpose", member_of(@purposes))
    address = Enum.join(octets, ".")
    request = PrivateServices.watch_request(address, purpose)
    assert PrivateServices.decode_watch_request(request) == {:ok, address, purpose}
  end

  property "hostile requests are refused",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_187_656_019 do
    address =
      draw(
        "address",
        member_of(["010.0.0.1", "1.2.3", "1.2.3.4.5", "256.1.1.1", "::1", " 1.2.3.4", ""])
      )

    purpose = draw("purpose", member_of(["services", "roster", "SSH_ROSTER", "", "ssh_roster "]))
    extra = draw("extra", boolean())
    version = draw("version", member_of([1, 2, 3, 4, "3"]))
    request = %{"version" => version, "address" => address, "purpose" => purpose}

    request =
      if extra do
        Map.put(request, "watch", true)
      else
        request
      end

    assert PrivateServices.decode_watch_request(request) == {:error, :invalid_request}
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
