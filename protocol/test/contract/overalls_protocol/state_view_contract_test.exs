defmodule OverallsProtocolStateViewContractTest do
  use Covenant.Case, component: "overalls_protocol.state_view"

  @tag obligation: "overalls_protocol.state_view.I1"
  test "declared modules compile and remain loadable" do
    modules = [OverallsProtocol.Cadence, OverallsProtocol.NestedStream, OverallsProtocol.View]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
