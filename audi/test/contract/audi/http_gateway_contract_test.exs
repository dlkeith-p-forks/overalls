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
end
