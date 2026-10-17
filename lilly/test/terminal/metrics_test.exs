defmodule Lilly.Terminal.MetricsTest do
  use ExUnit.Case, async: false
  alias Lilly.Terminal.Metrics

  test "terminal observations are scoped numeric data and stream ownership ends with the process" do
    host = Lilly.UUID.generate()
    placement = Lilly.UUID.generate()

    Metrics.dial(
      %{host_id: host, placement_id: placement, execution_epoch: 2, generation: 3},
      true
    )

    Metrics.dial(
      %{host_id: host, placement_id: placement, execution_epoch: 2, generation: 3},
      false
    )

    Metrics.proxy_error(host)
    Metrics.report(host, 4)
    snapshot = Metrics.snapshot(host)
    assert snapshot.gauges == %{terminal_live_channels: 4}
    assert snapshot.counters == %{terminal_dial_failures: 1, terminal_proxy_errors: 1}

    assert [
             %{
               placement_id: ^placement,
               execution_epoch: 2,
               generation: 3,
               reachable: 0,
               age_ms: age
             }
           ] = snapshot.vms

    assert age >= 0
    assert Metrics.snapshot(Lilly.UUID.generate()).vms == []
  end

  test "malformed identity does not manufacture guest reachability" do
    host = Lilly.UUID.generate()
    :ok = Metrics.dial(%{host_id: host}, false)
    assert Metrics.snapshot(host).vms == []
  end
end
