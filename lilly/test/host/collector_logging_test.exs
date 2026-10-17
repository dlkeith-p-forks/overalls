defmodule Lilly.Host.CollectorLoggingTest do
  use ExUnit.Case, async: false
  alias Lilly.Host.Collector
  @metadata [:event, :reason]

  test "collection failures emit a closed reason and keep the unavailable result" do
    pool = %{filesystem_id: "fixture-fs", storage: %{dataset: "tank", zpool_guid: 1}, extents: []}

    log =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        assert {:error, :collection_failed} =
                 Collector.sample([pool, pool], "/sys/fs/cgroup/lilly.slice", nil, 1)
      end)

    assert log =~ "lilly.collection_failed"
    assert log =~ "reason=pools_indistinct"
  end
end
