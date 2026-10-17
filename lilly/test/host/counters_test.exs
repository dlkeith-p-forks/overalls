defmodule Lilly.Host.CountersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Lilly.Host.Counters

  test "CPU guest counters are not added twice and reset observations stay unknown" do
    assert {:ok, %{total: 100, idle: 50}} =
             Counters.cpu("cpu 20 10 10 40 10 2 3 5 10 5\ncpu0 ignored")

    assert 75.0 == Counters.cpu_percent(%{total: 100, idle: 50}, %{total: 200, idle: 75})
    assert nil == Counters.cpu_percent(%{total: 100, idle: 50}, %{total: 50, idle: 10})
    assert nil == Counters.cpu_percent(nil, %{total: 50, idle: 10})
  end

  property "CPU usage stays in range for increasing counters" do
    check all(
            total <- integer(1..1_000_000),
            idle <- integer(0..total),
            delta <- integer(1..1_000_000),
            idle_delta <- integer(0..delta)
          ) do
      percent =
        Counters.cpu_percent(%{total: total, idle: idle}, %{
          total: total + delta,
          idle: idle + idle_delta
        })

      assert percent >= 0.0 and percent <= 100.0
    end
  end
end
