defmodule LillyNetworkTerminalContractTest do
  use Covenant.Case, component: "lilly.network_terminal"

  @tag obligation: "lilly.network_terminal.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Lilly.Ingress.Backend,
      Lilly.Ingress.Guardian,
      Lilly.Ingress.Server,
      Lilly.Ingress.SocketCustody,
      Lilly.Network,
      Lilly.Network.Attribution,
      Lilly.Network.AttributionServer,
      Lilly.Network.Config,
      Lilly.Network.FlowLabel,
      Lilly.Network.FlowLookup,
      Lilly.Network.Guest,
      Lilly.Network.Ingress,
      Lilly.Network.Policy,
      Lilly.Network.ProxyRouting,
      Lilly.Terminal.Channel,
      Lilly.Terminal.Guest,
      Lilly.Terminal.Metrics,
      Lilly.Terminal.Stream,
      Lilly.Terminal.Vsock
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
