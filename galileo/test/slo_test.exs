defmodule Galileo.SLOTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  setup do
    start_supervised!({Galileo.SLO, []})
    :ok
  end

  # @cc [owner:ghuntley,label:verification] galileo-slo-generated-outcomes
  # Generated terminal histories MUST preserve cumulative outcome arithmetic,
  # exactly one duration bucket per admitted request and fixed snapshot keys.
  property "generated admitted outcomes have closed cumulative buckets" do
    check all(
            outcomes <-
              list_of({boolean(), integer(0..11_000_000)}, min_length: 1, max_length: 80)
          ) do
      before = Galileo.SLO.snapshot()

      for {success, duration} <- outcomes do
        :ok = Galileo.SLO.record(success, duration)
      end

      after_snapshot = Galileo.SLO.snapshot()
      successful = Enum.count(outcomes, fn {success, _} -> success end)
      durations = Enum.map(outcomes, fn {_, duration} -> duration end)
      bounds = after_snapshot.duration.explicit_bounds_us

      expected_buckets =
        Enum.map(0..length(bounds), fn index ->
          Enum.count(durations, fn duration ->
            Enum.find_index(bounds, &(duration <= &1)) == index or
              (index == length(bounds) and duration > List.last(bounds))
          end)
        end)

      assert after_snapshot.requests - before.requests == length(outcomes)
      assert after_snapshot.successes - before.successes == successful
      assert after_snapshot.failures - before.failures == length(outcomes) - successful
      assert after_snapshot.duration.count == after_snapshot.requests
      assert after_snapshot.duration.sum_us - before.duration.sum_us == Enum.sum(durations)

      assert Enum.zip_with(
               after_snapshot.duration.bucket_counts,
               before.duration.bucket_counts,
               &-/2
             ) ==
               expected_buckets

      assert Map.keys(after_snapshot) |> Enum.sort() ==
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

      assert after_snapshot.service == "galileo"
      assert after_snapshot.incarnation == before.incarnation
    end
  end
end
