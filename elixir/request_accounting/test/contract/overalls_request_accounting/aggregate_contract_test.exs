defmodule OverallsRequestAccountingAggregateContractTest do
  use Covenant.Case, component: "overalls_request_accounting.aggregate"

  @tag obligation: "overalls_request_accounting.aggregate.I1"
  test "declared modules compile and remain loadable" do
    modules = [Overalls.RequestAccounting.Aggregate]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
