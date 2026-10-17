defmodule OverallsProtocol.IngressRouteTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.IngressRoute
  @id "00000000-0000-4000-8000-000000000001"

  property "readiness preserves execution and digest and rejects caller publication authority",
    database: :disabled,
    print_blob: false,
    test_cases: 30,
    seed: 472_393_697 do
    epoch = draw("epoch", integer(1..9_223_372_036_854_775_807))
    digest = draw("digest", binary(length: 32))
    key = draw("key", member_of(["addresses", "ttl", "host_id", "user_id", "service_token"]))
    fingerprint = Base.encode16(digest, case: :lower)

    value = %{
      "version" => 1,
      "vm_id" => @id,
      "placement_id" => @id,
      "execution_epoch" => epoch,
      "generation" => 1,
      "service_generation" => 1,
      "certificate_fingerprint" => fingerprint,
      "certificate_expires_at" => "2030-01-01T00:00:00Z"
    }

    assert {:ok, %{execution_epoch: ^epoch, certificate_fingerprint: ^fingerprint}} =
             IngressRoute.request(value)

    assert {:error, :invalid_request} = IngressRoute.request(Map.put(value, key, "forged"))

    for field <- Map.keys(value) do
      assert {:error, :invalid_request} = IngressRoute.request(Map.delete(value, field))
    end

    assert {:error, :invalid_request} =
             IngressRoute.request(%{value | "certificate_expires_at" => "not-a-time"})

    assert {:error, :invalid_request} = IngressRoute.request(%{value | "version" => 2})
  end

  test "acknowledgements require closed bounded metadata" do
    route = %{
      "id" => @id,
      "revision" => 1,
      "label" => "vm-00000000000040008000000000000001",
      "certificate_fingerprint" => String.duplicate("a", 64),
      "expires_at" => "2030-01-01T00:00:00Z"
    }

    assert {:ok, _} = IngressRoute.response(%{"version" => 1, "route" => route})

    for changed <- [
          Map.put(route, "ttl", 60000),
          %{route | "revision" => 0},
          %{route | "expires_at" => nil}
        ] do
      assert {:error, :invalid_message} =
               IngressRoute.response(%{"version" => 1, "route" => changed})
    end
  end
end
