defmodule OverallsProtocol.EgressAttributionTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.EgressAttribution, as: Wire
  @id "11111111-1111-4111-8111-111111111111"

  property "complete tuples round trip with strict framing and version",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_456_735_329 do
    a = draw("a", integer(0..255))
    port = draw("port", integer(1..65535))
    flow = %{source: {{10, 10, 0, a}, port}, destination: {{8, 8, 8, 8}, 443}}
    bytes = Wire.request(flow)
    assert byte_size(bytes) == 13
    assert Wire.decode_request(bytes) == {:ok, flow}
    assert Wire.decode_request(bytes <> <<0>>) == {:error, :invalid_message}
    <<1, rest::binary>> = bytes
    assert Wire.decode_request(<<2, rest::binary>>) == {:error, :invalid_message}
  end

  test "responses exclude partial, invalid and unbounded identity" do
    identity = %{
      host_id: @id,
      vm_id: @id,
      placement_id: @id,
      owner_id: @id,
      execution_epoch: 1,
      generation: 2,
      attribution: :resolved
    }

    bytes = Wire.response({:ok, identity})
    assert byte_size(bytes) == 162
    assert Wire.decode_response(bytes) == {:ok, identity}

    for invalid <- [
          bytes <> <<0>>,
          binary_part(bytes, 0, 161),
          <<2, 0>>,
          <<1, 0>>,
          Wire.response({:ok, %{identity | execution_epoch: 0}}),
          Wire.response({:ok, %{identity | generation: 9_223_372_036_854_775_808}}),
          Wire.response({:ok, %{identity | owner_id: String.duplicate("x", 36)}})
        ] do
      assert Wire.decode_response(invalid) == {:error, :unresolved}
    end

    assert Wire.response({:error, :unresolved}) == <<1, 0>>
  end
end
