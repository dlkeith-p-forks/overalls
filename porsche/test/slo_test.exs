defmodule Porsche.SLOTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Porsche.{Observability, SLO}

  property "generated terminal command dispatches keep closed cumulative outcomes and buckets" do
    outcomes = draw(list_of(tuple({boolean(), integer(0..20_000_000)}), max_length: 100))

    final =
      Enum.reduce(outcomes, SLO.new(), fn {success, duration}, state ->
        SLO.record(state, success, duration)
      end)

    snapshot = SLO.snapshot(final)
    assert snapshot.requests == length(outcomes)
    assert snapshot.successes == Enum.count(outcomes, &elem(&1, 0))
    assert snapshot.failures == snapshot.requests - snapshot.successes
    assert snapshot.duration.count == snapshot.requests
    assert snapshot.duration.sum_us == Enum.reduce(outcomes, 0, &(&2 + elem(&1, 1)))
    assert Enum.sum(snapshot.duration.bucket_counts) == snapshot.requests
    bounds = snapshot.duration.explicit_bounds_us

    assert snapshot.duration.bucket_counts ==
             Enum.map(0..length(bounds), fn index ->
               Enum.count(outcomes, fn {_success, duration} ->
                 Enum.find_index(bounds, &(duration <= &1)) == index or
                   (index == length(bounds) and duration > List.last(bounds))
               end)
             end)

    refute inspect(snapshot) =~ "command"
  end

  test "terminal SSH telemetry reaches the cumulative source without changing interval summaries" do
    before = Observability.slo_snapshot()

    Observability.observe(
      [:porsche, :ssh, :complete],
      %{duration_us: 55_000, error: 1, eligible: true},
      %{command: "private-command", session: "private-session"},
      nil
    )

    after_snapshot = Observability.slo_snapshot()
    assert after_snapshot.requests == before.requests + 1
    assert after_snapshot.failures == before.failures + 1
    assert after_snapshot.duration.count == before.duration.count + 1
    refute inspect(after_snapshot) =~ "private-command"
    refute inspect(after_snapshot) =~ "private-session"
  end

  test "invalid and forbidden command results stay outside candidate denominator" do
    before = Observability.slo_snapshot()

    assert %{exit_status: 2} =
             Observability.measure(:ssh, fn -> %{exit_status: 2} end)

    assert %{exit_status: 3} =
             Observability.measure(:ssh, fn -> %{exit_status: 3} end)

    assert Observability.slo_snapshot().requests == before.requests
  end
end
