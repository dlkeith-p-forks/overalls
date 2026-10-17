defmodule BradyProxyContractTest do
  use Covenant.Case, component: "brady.proxy"

  @tag obligation: "brady.proxy.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Brady.Connection,
      Brady.HTTP.Head,
      Brady.HTTP.Stream,
      Brady.Log,
      Brady.Proxy,
      Brady.TLS,
      Brady.TLS.Certificates,
      Brady.TLS.Hello,
      Brady.Tunnel,
      Brady.Upstream
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
