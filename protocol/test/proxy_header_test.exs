defmodule OverallsProtocol.ProxyHeaderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias OverallsProtocol.{IngressConnect, ProxyHeader}
  @id "11111111-1111-4111-8111-111111111111"

  property "IPv4 metadata has fixed framing and exact endpoints" do
    check all(a <- integer(0..255), b <- integer(0..255), port <- integer(1..65535)) do
      peer = %{address: "192.0.#{a}.#{b}", port: port}
      assert {:ok, bytes} = ProxyHeader.encode(peer, "10.41.0.2", 443)
      assert byte_size(bytes) == 28

      assert {:ok, %{source: {{192, 0, ^a, ^b}, ^port}, destination: {{10, 41, 0, 2}, 443}}} =
               ProxyHeader.decode(bytes)

      assert {:error, _} = ProxyHeader.decode(bytes <> <<0>>)
      assert {:error, _} = ProxyHeader.encode(%{peer | address: "::1"}, "10.41.0.2", 443)
      assert {:error, _} = ProxyHeader.encode(peer, "10.041.0.2", 443)
    end
  end

  test "metadata is separate from the nested lease and cannot widen destinations" do
    base = %{
      vm_id: @id,
      host_id: @id,
      placement_id: @id,
      session_id: @id,
      execution_epoch: 1,
      generation: 1,
      environment_generation: 1,
      label: OverallsProtocol.IngressName.label("lab", @id),
      service: :audi_https,
      port: 443
    }

    binding = Map.put(base, :client_peer, %{address: "203.0.113.9", port: 12345})
    assert {:ok, bytes} = IngressConnect.encode(binding)
    assert {:ok, ^binding} = IngressConnect.decode(bytes)
    wire = JSON.decode!(bytes)
    refute Map.has_key?(wire["binding"], "client_peer")

    for changed <- [
          put_in(wire, ["peer", "address"], "::1"),
          put_in(wire, ["peer", "port"], 0),
          put_in(wire, ["peer", "extra"], true),
          put_in(wire, ["binding", "service"], "audi_ssh"),
          Map.put(wire, "extra", true)
        ] do
      assert {:error, _} = IngressConnect.decode(JSON.encode!(changed))
    end

    refute IngressConnect.valid?(%{binding | service: :audi_ssh, port: 22})
  end
end
