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
end
