defmodule OverallsProtocol.NestedStreamTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias OverallsProtocol.{IngressName, NestedStream}
  @id "11111111-1111-4111-8111-111111111111"
  @label IngressName.label("lab", @id)
  @ticket "audi_nested_stream_" <> Base.url_encode64(<<0::256>>, padding: false)

  test "requests keep fixed service selectors and token purposes closed" do
    request = %{
      "version" => 1,
      "label" => @label,
      "nested_service" => "control_https",
      "public_key" => nil
    }

    assert {:ok, :open_nested, %{nested_service: :control_https}} =
             NestedStream.request("nested-open", request)

    for bad <- [
          Map.put(request, "port", 443),
          Map.put(request, "version", 2),
          Map.put(request, "nested_service", "tcp"),
          Map.put(request, "public_key", "key"),
          Map.put(request, "nested_service", "porsche_ssh")
        ] do
      assert {:error, :invalid_message} = NestedStream.request("nested-open", bad)
    end

    assert {:ok, :renew_nested, _} =
             NestedStream.request("nested-renew", %{"version" => 1, "stream_token" => @ticket})

    refute NestedStream.ticket?(String.replace(@ticket, "nested", "web"))
  end

  test "reply binding, expiry and renewal identity are exact" do
    binding = %{
      host_id: @id,
      vm_id: @id,
      placement_id: @id,
      session_id: @id,
      execution_epoch: 1,
      generation: 1,
      environment_generation: 1,
      label: @label,
      service: :control_https,
      port: 443
    }

    expected = Map.take(binding, [:host_id, :label, :service])

    wire =
      %{version: 1, grant: %{binding: binding, ttl: 1000, host_key: nil, ticket: @ticket}}
      |> JSON.encode!()
      |> JSON.decode!()

    assert {:ok, grant} = NestedStream.response("nested-open", wire, expected)
    renewal = update_in(wire, ["grant"], &Map.delete(&1, "ticket"))
    assert {:ok, _} = NestedStream.response("nested-renew", renewal, expected, grant)

    for changed <- [
          put_in(renewal, ["grant", "binding", "environment_generation"], 2),
          put_in(renewal, ["grant", "ttl"], 30_001),
          put_in(renewal, ["grant", "ttl"], 0),
          put_in(renewal, ["grant", "host_key"], "ssh-ed25519 invalid"),
          put_in(renewal, ["grant", "binding", "port"], 22)
        ] do
      assert {:error, :invalid_message} =
               NestedStream.response("nested-renew", changed, expected, grant)
    end

    assert {:error, :invalid_message} =
             NestedStream.response("nested-open", wire, %{expected | label: "wrong"})
  end

  property "unstructured peer values never become requests or credentials" do
    check all(value <- binary(max_length: 8192)) do
      assert {:error, :invalid_message} = NestedStream.request("nested-open", value)
      refute NestedStream.ticket?(value)
    end
  end
end
