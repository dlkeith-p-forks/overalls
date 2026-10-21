defmodule Overalls.RequestAccounting.AggregateTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Overalls.RequestAccounting.Aggregate

  @bounds Aggregate.bounds()

  test "explicit source identity survives snapshot construction without opening arbitrary labels" do
    options = [
      started_at_unix_nano: 123,
      incarnation: String.duplicate("a", 32),
      invocation_id: String.duplicate("b", 32)
    ]

    snapshot = "enrico" |> Aggregate.new(options) |> Aggregate.snapshot()
    assert Map.take(snapshot, Keyword.keys(options)) == Map.new(options)
    assert Aggregate.validate_snapshot(snapshot) == :ok

    for invalid <- [
          options ++ [private_label: "private-canary"],
          options ++ [invocation_id: String.duplicate("c", 32)],
          Keyword.put(options, :incarnation, "private-canary")
        ] do
      assert_raise ArgumentError, fn -> Aggregate.new("enrico", invalid) end
    end
  end

  # @cc [owner:ghuntley,label:verification] aggregate-conservation-property
  # Every generated terminal history MUST conserve requests as successes plus
  # failures, and every measured duration MUST occupy exactly one fixed slot.
  property "terminal histories conserve outcomes and measured durations" do
    events =
      draw(
        "events",
        list_of(
          tuple(
            {member_of([:success, :failure]), one_of([constant(nil), integer(0..20_000_000)])}
          ),
          max_length: 100
        )
      )

    aggregate =
      Enum.reduce(events, Aggregate.new("enrico"), fn {outcome, duration}, state ->
        Aggregate.record(state, outcome, duration)
      end)

    snapshot = Aggregate.snapshot(aggregate)
    measured = Enum.count(events, &(elem(&1, 1) != nil))

    assert snapshot.requests == length(events)
    assert snapshot.requests == snapshot.successes + snapshot.failures
    assert snapshot.duration.count == measured
    assert Enum.sum(snapshot.duration.bucket_counts) == measured
    assert Aggregate.validate_snapshot(snapshot) == :ok
  end

  test "boundary values use inclusive explicit bounds and overflow bucket" do
    state = Aggregate.new("enrico")

    state =
      Enum.reduce(@bounds ++ [List.last(@bounds) + 1], state, fn duration, state ->
        Aggregate.record(state, :success, duration)
      end)

    assert Tuple.to_list(state.bucket_counts) == List.duplicate(1, 8)
    assert Aggregate.bucket_index(0) == 0
    assert Aggregate.bucket_index(List.last(@bounds)) == 6
    assert Aggregate.bucket_index(List.last(@bounds) + 1) == 7
  end

  test "excluded and missing durations do not fabricate observations" do
    state = Aggregate.new("enrico")
    state = Aggregate.record(state, :exclude, 100)
    state = Aggregate.record(state, :failure, nil)
    snapshot = Aggregate.snapshot(state)

    assert snapshot.requests == 1
    assert snapshot.failures == 1

    assert snapshot.duration == %{
             count: 0,
             sum_us: 0,
             explicit_bounds_us: @bounds,
             bucket_counts: List.duplicate(0, 8)
           }
  end

  test "snapshot validation rejects conservation and schema violations" do
    snapshot = Aggregate.snapshot(Aggregate.new("enrico"))

    assert {:error, :invalid_counts} =
             Aggregate.validate_snapshot(%{snapshot | successes: 1})

    assert {:error, :invalid_duration} =
             Aggregate.validate_snapshot(put_in(snapshot, [:duration, :explicit_bounds_us], [1]))

    assert {:error, :invalid_snapshot} =
             Aggregate.validate_snapshot(Map.put(snapshot, :private_label, "excluded"))

    assert {:error, :invalid_service} =
             Aggregate.validate_snapshot(%{snapshot | service: "unreviewed"})

    assert_raise ArgumentError, fn -> Aggregate.new("unreviewed") end
  end

  test "counter and duration overflow preserve a valid measurable projection" do
    maximum = Aggregate.max_counter()

    full = %Aggregate{
      service: "enrico",
      started_at_unix_nano: 1,
      incarnation: String.duplicate("a", 32),
      invocation_id: String.duplicate("b", 32),
      requests: maximum,
      successes: maximum,
      failures: 0,
      duration_count: maximum,
      duration_sum_us: maximum,
      bucket_counts: {maximum, 0, 0, 0, 0, 0, 0, 0}
    }

    assert Aggregate.record(full, :failure, 1) == full

    near_sum = %{
      full
      | requests: maximum - 1,
        successes: maximum - 1,
        duration_count: 0,
        duration_sum_us: maximum,
        bucket_counts: {0, 0, 0, 0, 0, 0, 0, 0}
    }

    result = Aggregate.record(near_sum, :failure, maximum)
    assert result.requests == maximum
    assert result.failures == 1
    assert result.duration_count == 0
    assert Aggregate.validate_snapshot(Aggregate.snapshot(result)) == :ok
  end
end
