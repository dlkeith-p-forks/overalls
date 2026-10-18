defmodule Enrico.SLOTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Enrico.SLO

  # @cc [owner:ghuntley,label:verification] enrico-slo-generated-attempts
  # Generated terminal histories MUST preserve closed cumulative arithmetic,
  # one duration bucket per attempt and fixed snapshot keys without identity.
  property "generated terminal refreshes have closed cumulative outcomes",
    profile: :ci,
    test_cases: 1 do
    check all(
            outcomes <-
              list_of({boolean(), integer(0..11_000_000)}, min_length: 1, max_length: 80)
          ) do
      final =
        Enum.reduce(outcomes, SLO.new(), fn {success, duration}, acc ->
          SLO.record(acc, success, duration)
        end)

      snapshot = SLO.snapshot(final)
      successes = Enum.count(outcomes, fn {success, _} -> success end)
      durations = Enum.map(outcomes, fn {_, duration} -> duration end)
      bounds = snapshot.duration.explicit_bounds_us

      assert snapshot.requests == length(outcomes)
      assert snapshot.successes == successes
      assert snapshot.failures == length(outcomes) - successes
      assert snapshot.duration.count == snapshot.requests
      assert snapshot.duration.sum_us == Enum.sum(durations)

      assert snapshot.duration.bucket_counts ==
               Enum.map(0..length(bounds), fn index ->
                 Enum.count(durations, fn duration ->
                   Enum.find_index(bounds, &(duration <= &1)) == index or
                     (index == length(bounds) and duration > List.last(bounds))
                 end)
               end)

      assert Map.keys(snapshot) |> Enum.sort() ==
               [
                 :duration,
                 :failures,
                 :incarnation,
                 :invocation_id,
                 :requests,
                 :sampled_at_unix_nano,
                 :service,
                 :started_at_unix_nano,
                 :successes,
                 :version
               ]

      assert snapshot.service == "enrico"
    end
  end
end
