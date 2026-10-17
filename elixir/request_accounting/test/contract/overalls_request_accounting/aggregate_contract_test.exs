defmodule OverallsRequestAccountingAggregateContractTest do
  use Covenant.Case, component: "overalls_request_accounting.aggregate"

  @tag obligation: "overalls_request_accounting.aggregate.I1"
  test "declared modules compile and remain loadable" do
    modules = [Overalls.RequestAccounting.Aggregate]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "overalls_request_accounting.aggregate.I2"
  test "recording preserves outcome counts and excludes are identity" do
    state = Overalls.RequestAccounting.Aggregate.new("marshall_web")
    state = Overalls.RequestAccounting.Aggregate.record(state, :success, 12)
    state = Overalls.RequestAccounting.Aggregate.record(state, :failure, 60_000)
    assert state.requests == 2
    assert state.successes == 1
    assert state.failures == 1
    assert Overalls.RequestAccounting.Aggregate.record(state, :exclude, 10) == state
  end

  @tag obligation: "overalls_request_accounting.aggregate.I3"
  test "snapshots validate and reject tampered counts" do
    state = Overalls.RequestAccounting.Aggregate.new("marshall_web")
    snapshot = Overalls.RequestAccounting.Aggregate.snapshot(state)
    assert :ok = Overalls.RequestAccounting.Aggregate.validate_snapshot(snapshot)
    tampered = Map.put(snapshot, :requests, 1)
    assert {:error, _} = Overalls.RequestAccounting.Aggregate.validate_snapshot(tampered)
  end
end
