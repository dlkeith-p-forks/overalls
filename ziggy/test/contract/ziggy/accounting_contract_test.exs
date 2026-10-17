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

  @tag obligation: "ziggy.accounting.I4"
  test "completion validation rejects unknown fields and out of range values" do
    valid = %{
      "outcome" => "completed",
      "tokens" => %{"total_tokens" => 2},
      "completeness" => "complete",
      "duration_ms" => 10,
      "request_bytes" => 1,
      "response_bytes" => 2,
      "provider_request_id" => "req-1",
      "http_status" => 200
    }

    assert {:ok, ^valid} = Ziggy.Completion.validate(valid)
    assert {:error, :invalid_request} = Ziggy.Completion.validate(Map.put(valid, "secret", "x"))
    assert {:error, :invalid_request} =
             Ziggy.Completion.validate(%{valid | "duration_ms" => -1})
  end

  @tag obligation: "ziggy.accounting.I5"
  test "version fence backoff doubles and caps" do
    fence = Ziggy.VersionFence.new(fence_backoff_ms: 30_000)
    {fence, 30_000, _} = Ziggy.VersionFence.refused(fence)
    {_fence, 60_000, _} = Ziggy.VersionFence.refused(fence)
  end
end
