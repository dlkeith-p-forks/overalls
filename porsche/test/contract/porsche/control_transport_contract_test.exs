defmodule PorscheControlTransportContractTest do
  use Covenant.Case, component: "porsche.control_transport"

  @tag obligation: "porsche.control_transport.I1"
  test "declared modules compile and remain loadable" do
    modules = [Porsche.Client, Porsche.Connection, Porsche.Control.Link, Porsche.Runner]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
