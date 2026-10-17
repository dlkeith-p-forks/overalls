defmodule AudiHttpGatewayContractTest do
  use Covenant.Case, component: "audi.http_gateway"

  @tag obligation: "audi.http_gateway.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Audi.Connector,
      Audi.HTTP.Authority,
      Audi.HTTP.Browser,
      Audi.HTTP.Editor,
      Audi.HTTP.EditorAssets,
      Audi.HTTP.EditorAssetsProbe,
      Audi.HTTP.EditorAssetsPublisher,
      Audi.HTTP.EditorBrowser,
      Audi.HTTP.Front,
      Audi.HTTP.Headers,
      Audi.HTTP.Listener,
      Audi.HTTP.Proxy,
      Audi.HTTP.TLSTransport,
      Audi.HTTP.WebSocket,
      Audi.HTTP.WebSocketFrame,
      Audi.HTTP.WebSocketUpgrade,
      Audi.Inception.Authority,
      Audi.Inception.ClientHello,
      Audi.Inception.Front,
      Audi.Inception.Peer
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "audi.http_gateway.I2"
  test "response cookies lose domain and reserved cookies" do
    assert {:ok, headers} =
             Audi.HTTP.Headers.response([
               {"set-cookie", "sid=x; Domain=evil.test; Path=/"},
               {"set-cookie", "__host-audi_token=y"}
             ])

    assert headers == [{"set-cookie", "sid=x; Path=/"}]
  end

  @tag obligation: "audi.http_gateway.I3"
  test "websocket frames round trip and reject oversized control payloads" do
    assert {:ok, encoded} = Audi.HTTP.WebSocketFrame.encode(:text, "hello")
    assert byte_size(encoded) > 0

    assert {:ok, %{opcode: 1, payload: "hello"}, <<>>} =
             Audi.HTTP.WebSocketFrame.decode(<<0x81, 5, "hello">>)

    assert :error = Audi.HTTP.WebSocketFrame.encode(:ping, String.duplicate("x", 126))
  end
end
