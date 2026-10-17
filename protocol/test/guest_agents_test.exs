defmodule OverallsProtocol.GuestAgentsTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.GuestAgents

  test "the capability table is closed and each set round-trips its wire name" do
    for set <- [:linux, :none, :windows_v1, :freebsd_v1, :illumos_v1] do
      assert {:ok, ^set} = GuestAgents.parse(GuestAgents.wire(set))
      capabilities = GuestAgents.capabilities(set)

      assert Enum.sort(Map.keys(capabilities)) ==
               ~w(agents editor flush inception readiness ssh terminal trust workspace)a
    end

    assert GuestAgents.capabilities(:linux) |> Map.values() |> Enum.all?()
    refute GuestAgents.capabilities(:none) |> Map.values() |> Enum.any?()

    assert %{inception: false, editor: false, readiness: true, trust: true, terminal: true} =
             GuestAgents.capabilities(:windows_v1)

    assert GuestAgents.capabilities(:freebsd_v1) == GuestAgents.capabilities(:illumos_v1)

    for value <- ["Linux", "windows", "windows-v2", "", nil, :linux, 1] do
      assert :error = GuestAgents.parse(value)
    end
  end

  test "vsock use and readiness budgets follow the table" do
    assert GuestAgents.vsock?(:linux)
    assert GuestAgents.vsock?(:windows_v1)
    refute GuestAgents.vsock?(:none)
    assert GuestAgents.readiness_budget_ms(:linux, :customer) == 120_000
    assert GuestAgents.readiness_budget_ms(:linux, :inception) == 2_400_000
    assert GuestAgents.readiness_budget_ms(:windows_v1, :customer) == 600_000
    assert GuestAgents.readiness_budget_ms(:windows_v1, :inception) == 600_000
    assert GuestAgents.vsock?(:freebsd_v1)
    assert GuestAgents.vsock?(:illumos_v1)
    assert GuestAgents.readiness_budget_ms(:freebsd_v1, :customer) == 600_000
    assert GuestAgents.readiness_budget_ms(:illumos_v1, :customer) == 600_000
  end
end
