defmodule OverallsProtocol.IngressWakeRelayTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.{IngressRelay, IngressWake}
  @source "11111111-1111-4111-8111-111111111111"
  @destination "22222222-2222-4222-8222-222222222222"
  @capability "audi_relay_" <> Base.url_encode64(<<0::256>>, padding: false)

  property "wake receipts reject expired, unbounded and execution-shaped authority",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 100_251 do
    ttl = draw("ttl", integer(-1..30_001))
    retry = draw("retry", integer(0..6000))

    receipt = %{
      "version" => 1,
      "pending" => %{"vm_id" => @source, "ttl" => ttl, "retry_after_ms" => retry}
    }

    assert match?({:ok, _}, IngressWake.decode(receipt)) ==
             (ttl in 1..30_000 and retry in 100..5000 and retry < ttl)

    assert {:error, :invalid_message} = IngressWake.decode(Map.put(receipt, "grant", %{}))
  end

  property "one-hop routes admit only canonical explicitly fleet addresses",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 100_252 do
    octet = draw("last_octet", integer(0..255))
    address = "10.90.0." <> Integer.to_string(octet)

    route = %{
      "origin_host_id" => @source,
      "destination_host_id" => @destination,
      "address" => address,
      "port" => 9445,
      "capability" => @capability
    }

    assert match?({:ok, _}, IngressRelay.route(route)) == octet in 1..254

    for invalid <- ["127.0.0.1", "10.90.1.1", "10.90.0.01", "::1", "example.test"] do
      assert {:error, :invalid_message} = IngressRelay.route(%{route | "address" => invalid})
    end

    assert {:error, :invalid_message} =
             IngressRelay.route(%{route | "destination_host_id" => @source})

    assert {:error, :invalid_message} = IngressRelay.route(Map.put(route, "next_hop", @source))
  end

  property "relay prefaces pin capability and service-specific ticket independently",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 100_253 do
    purpose = draw("purpose", member_of([:ssh, :web, :editor]))
    suffix = Base.url_encode64(<<0::256>>, padding: false)

    prefix =
      case purpose do
        :ssh -> "audi_session_"
        :web -> "audi_web_stream_"
        :editor -> "audi_editor_stream_"
      end

    ticket = prefix <> suffix
    assert {:ok, bytes} = IngressRelay.encode(@capability, ticket, purpose)

    assert {:ok, %{capability: @capability, ticket: ^ticket, purpose: ^purpose}} =
             IngressRelay.decode(bytes)

    wire = JSON.decode!(bytes)

    assert {:error, :invalid_message} =
             IngressRelay.decode(Map.put(wire, "peer_address", "10.90.0.1"))

    assert {:error, :invalid_message} = IngressRelay.decode(%{wire | "ticket" => @capability})
    assert {:error, :invalid_message} = IngressRelay.decode(String.duplicate("x", 4097))
  end
end
