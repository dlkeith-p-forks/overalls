defmodule ZiggyAccountingContractTest do
  use Covenant.Case, component: "ziggy.accounting"

  @tag obligation: "ziggy.accounting.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Ziggy.Catalog,
      Ziggy.Completion,
      Ziggy.Pricing,
      Ziggy.Reporter,
      Ziggy.SLO,
      Ziggy.SLOCheckpoint,
      Ziggy.Spool,
      Ziggy.Usage,
      Ziggy.VersionFence
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
