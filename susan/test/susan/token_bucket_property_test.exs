defmodule Susan.TokenBucketPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Susan.TokenBucket

  @hour 3_600_000

  test "the documented per-key limit admits a burst of ten then refuses" do
    limit = %{burst: 10, per_hour: 60}

    {bucket, admitted} =
      Enum.reduce(1..10, {nil, 0}, fn _, {bucket, count} ->
        {:ok, bucket} = TokenBucket.take(bucket, limit, 0)
        {bucket, count + 1}
      end)

    assert admitted == 10
    assert {:error, 60, true, bucket} = TokenBucket.take(bucket, limit, 0)
    assert {:error, _, false, bucket} = TokenBucket.take(bucket, limit, 1_000)
    assert {:ok, _} = TokenBucket.take(bucket, limit, 60_000)
  end

  @tag :hegel
  test "admissions never exceed burst plus refill and refusals name a sufficient wait" do
    Hegel.check(
      fn ->
        burst = draw("burst", integer(1, 50))
        rate = draw("rate", integer(1, 10_000))
        limit = %{burst: burst, per_hour: rate}
        steps = draw("steps", list_of(integer(-5_000, 120_000), max_length: 80))

        {_, now, admitted} =
          Enum.reduce(steps, {nil, 0, 0}, fn delta, {bucket, now, admitted} ->
            now = now + delta

            case TokenBucket.take(bucket, limit, now) do
              {:ok, next} ->
                assert next.level >= 0 and next.level <= burst * 1000
                {next, now, admitted + 1}

              {:error, retry, _first, next} ->
                assert retry > 0
                assert next.level < 1000
                # Waiting the advertised Retry-After always admits one request.
                assert {:ok, _} = TokenBucket.take(next, limit, max(now, next.at) + retry * 1000)
                {next, now, admitted}
            end
          end)

        span =
          max(
            Enum.reduce(steps, {0, 0}, fn d, {t, hi} -> {t + d, max(hi, t + d)} end) |> elem(1),
            now
          )

        assert admitted <= burst + div(span * rate, @hour) + 1
      end,
      test_cases: 300
    )
  end

  @tag :hegel
  test "time that does not advance never refills" do
    Hegel.check(
      fn ->
        burst = draw("burst", integer(1, 20))
        limit = %{burst: burst, per_hour: draw("rate", integer(1, 100_000))}
        at = draw("at", integer(0, 1_000_000))

        results =
          Enum.map_reduce(1..(burst + 5), nil, fn _, b ->
            case TokenBucket.take(b, limit, at) do
              {:ok, n} -> {:ok, n}
              {:error, _, _, n} -> {:error, n}
            end
          end)
          |> elem(0)

        assert Enum.count(results, &(&1 == :ok)) == burst
      end,
      test_cases: 200
    )
  end
end
