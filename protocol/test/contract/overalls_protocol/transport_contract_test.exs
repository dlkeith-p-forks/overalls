defmodule OverallsProtocolTransportContractTest do
  use Covenant.Case, component: "overalls_protocol.transport"

  @tag obligation: "overalls_protocol.transport.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      OverallsProtocol.Control.Client,
      OverallsProtocol.Control.Close,
      OverallsProtocol.Control.Envelope,
      OverallsProtocol.WebSocket.Connection,
      OverallsProtocol.WebSocket.Frame,
      OverallsProtocol.WebSocket.Handshake
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "overalls_protocol.transport.I2"
  test "control envelope accepts closed valid messages and rejects unknown fields" do
    assert {:ok, {:ping, 3}} = OverallsProtocol.Control.Envelope.decode(~s({"k":"ping","n":3}))

    assert {:error, :invalid_message} =
             OverallsProtocol.Control.Envelope.decode(~s({"k":"bogus"}))

    assert {:error, :invalid_message} =
             OverallsProtocol.Control.Envelope.decode(
               ~s({"k":"req","id":1,"op":"x","body":{},"extra":true})
             )

    assert {:error, :unsupported_version} =
             OverallsProtocol.Control.Envelope.decode(
               ~s({"k":"hello","v":2,"service":"a","bind":{}})
             )
  end

  @tag obligation: "overalls_protocol.transport.I3"
  test "control envelope rejects arbitrary names and malformed JSON" do
    assert {:error, :invalid_message} =
             OverallsProtocol.Control.Envelope.decode(
               ~s({"k":"req","id":1,"op":"Bad Name","body":{}})
             )

    assert {:error, :invalid_message} =
             OverallsProtocol.Control.Envelope.decode("not-json")

    assert {:error, :invalid_message} =
             OverallsProtocol.Control.Envelope.decode(~s({"k":"unknown","payload":{}}))
  end
end
