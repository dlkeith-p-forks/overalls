defmodule OverallsProtocol.InceptionObservationTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.InceptionObservation
  @id "11111111-1111-4111-8111-111111111111"
  @proof Base.url_encode64(<<0::256>>, padding: false)

  test "only bounded relative proof sets and a previous request correlation are accepted" do
    record = %{"label" => "control", "proofs" => [@proof], "ttl_ms" => 5000}
    value = %{"request_id" => @id, "records" => [record]}
    assert {:ok, nil} = InceptionObservation.validate(nil)
    assert {:ok, ^value} = InceptionObservation.validate(value)
    assert {:ok, _} = InceptionObservation.validate(%{value | "records" => []})

    for invalid <- [
          Map.put(value, "request_id", "bad"),
          Map.put(value, "expires_at", 123),
          Map.put(value, "records", List.duplicate(record, 17)),
          Map.put(value, "records", [record, record])
        ] do
      assert {:error, :invalid_inception_observation} = InceptionObservation.validate(invalid)
    end

    for {field, invalid} <- [
          {"ttl_ms", 0},
          {"ttl_ms", 5001},
          {"ttl_ms", true},
          {"label", "other.example"},
          {"proofs", []},
          {"proofs", [@proof, @proof]},
          {"proofs", [@proof <> "="]},
          {"address", "192.0.2.1"}
        ] do
      assert {:error, :invalid_inception_observation} =
               InceptionObservation.validate(%{
                 value
                 | "records" => [Map.put(record, field, invalid)]
               })
    end
  end
end
