defmodule OverallsRequestAccountingRecorderContractTest do
  use Covenant.Case, component: "overalls_request_accounting.recorder"

  @tag obligation: "overalls_request_accounting.recorder.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Overalls.RequestAccounting.Config,
      Overalls.RequestAccounting.Producer,
      Overalls.RequestAccounting.Producer.Server,
      Overalls.RequestAccounting.QualityMarker,
      Overalls.RequestAccounting.RecorderRPC
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
