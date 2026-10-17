defmodule Ziggy.SLOTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Ziggy.SLO

  # @cc [owner:ghuntley,label:verification] ziggy-slo-generated-completions
  # Generated durable completions MUST preserve closed outcomes, exclude
  # caller cancellations and leave unknown duration outside the histogram.
  property "generated durable completions preserve closed outcomes and optional duration" do
    check all(
            outcomes <-
              list_of(
                tuple(
                  {member_of(~w(completed upstream_error interrupted cancelled)),
                   one_of([constant(nil), integer(0..20_000)])}
                ),
                max_length: 100
              )
          ) do
      completions =
        Enum.map(outcomes, fn {outcome, duration} ->
          %{
            "outcome" => outcome,
            "http_status" => if(outcome == "completed", do: 200, else: nil),
            "duration_ms" => duration,
            "request_id" => "private-request",
            "model" => "private-model"
          }
        end)

      snapshot =
        completions
        |> Enum.reduce(SLO.new(), &SLO.record(&2, &1))
        |> SLO.snapshot()

      included = Enum.reject(outcomes, fn {outcome, _} -> outcome == "cancelled" end)
      successes = Enum.count(included, fn {outcome, _} -> outcome == "completed" end)

      measured =
        Enum.flat_map(included, fn {_, duration} ->
          if is_nil(duration), do: [], else: [duration]
        end)

      assert snapshot.requests == length(included)
      assert snapshot.successes == successes
      assert snapshot.failures == length(included) - successes
      assert snapshot.duration.count == length(measured)
      assert snapshot.duration.sum_us == Enum.sum(measured) * 1000
      assert Enum.sum(snapshot.duration.bucket_counts) == length(measured)
      bounds = snapshot.duration.explicit_bounds_us

      assert snapshot.duration.bucket_counts ==
               Enum.map(0..length(bounds), fn index ->
                 Enum.count(measured, fn duration_ms ->
                   duration_us = duration_ms * 1000

                   Enum.find_index(bounds, &(duration_us <= &1)) == index or
                     (index == length(bounds) and duration_us > List.last(bounds))
                 end)
               end)

      refute inspect(snapshot) =~ "private-request"
      refute inspect(snapshot) =~ "private-model"
    end
  end
end
