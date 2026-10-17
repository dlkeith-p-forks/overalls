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

  @tag obligation: "ziggy.accounting.I2"
  test "version fences require the current probe and recover on acceptance" do
    fence = Ziggy.VersionFence.new(fence_backoff_ms: 10)
    {fenced, 10, token} = Ziggy.VersionFence.refused(fence)
    assert Ziggy.VersionFence.fenced?(fenced)
    assert Ziggy.VersionFence.probe?(fenced, token)
    refute Ziggy.VersionFence.probe?(fenced, make_ref())
    refute Ziggy.VersionFence.fenced?(Ziggy.VersionFence.accepted(fenced))
  end

  @tag obligation: "ziggy.accounting.I3"
  test "completion wire keeps only accounting fields" do
    assert Ziggy.Completion.wire(%{"outcome" => :ok, "tokens" => 2, "ignored" => :secret}) ==
             %{"outcome" => :ok, "tokens" => 2}
  end
end
