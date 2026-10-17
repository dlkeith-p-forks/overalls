defmodule Lilly.Host.CollectorNativeIOTest do
  use ExUnit.Case, async: true
  alias Lilly.Host.Collector

  @pool %{
    id: "11111111-1111-4111-8111-111111111111",
    path: "/nonexistent/lilly-collector-native-io",
    filesystem_id: "fixture-fs",
    storage: %{backend: :zfs, dataset: "tank/lilly", zpool_guid: 1},
    backend: :zfs,
    extents: []
  }

  # @cc [owner:ghuntley,label:verification;capacity] collector-native-io-excluded
  # A capacity wire report MUST exclude native I/O diagnostics even when supplied.
  # Capacity sampling MUST not wait for an independent observability collector.
  test "native I/O diagnostics never enter the admission report" do
    measured = %{"status" => "measured", "source" => "openzfs_zpool_iostat", "read_iops" => 7}

    result = Collector.sample([@pool], "/sys/fs/cgroup", nil, 1, [], %{}, %{@pool.id => measured})

    case result do
      {:ok, report, _previous} ->
        [pool] = report.pools
        refute Map.has_key?(pool, :io)
        refute Map.has_key?(report, :utilization)

        {:ok, report, _} = Collector.sample([@pool], "/sys/fs/cgroup", nil, 2)
        [pool] = report.pools
        refute Map.has_key?(pool, :io)

      {:error, reason} ->
        flunk("host inventory unavailable in this environment: #{inspect(reason)}")
    end
  end
end
