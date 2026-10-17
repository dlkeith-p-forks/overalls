defmodule GalileoAuthorizedProxyContractTest do
  use Covenant.Case, component: "galileo.authorized_proxy"

  @tag obligation: "galileo.authorized_proxy.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Galileo.Application,
      Galileo.Config,
      Galileo.Control,
      Galileo.Counter,
      Galileo.Credential,
      Galileo.Events,
      Galileo.HTTP,
      Galileo.Privacy,
      Galileo.SLO,
      Galileo.Strip,
      Galileo.Upstream
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
