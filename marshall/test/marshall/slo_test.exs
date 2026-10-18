defmodule Marshall.SLOTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.SLO

  # @cc [owner:ghuntley,label:verification] marshall-browser-slo-partition
  # Generated HTTP statuses MUST form a closed success/failure denominator
  # only for completed browser transport, with one latency bucket per outcome.
  property "candidate browser outcomes retain closed counts and fixed buckets" do
    statuses = draw("statuses", list_of(integer(100..599), min_length: 1, max_length: 100))
    durations = draw("durations", list_of(integer(0..20_000_000), length: length(statuses)))

    slo =
      Enum.zip(statuses, durations)
      |> Enum.reduce(SLO.new(), fn {status, duration}, state ->
        SLO.observe(state, status, duration)
      end)

    included = Enum.count(statuses, &(SLO.classify(&1) != :exclude))
    successes = Enum.count(statuses, &(SLO.classify(&1) == :success))
    snapshot = SLO.snapshot(slo)

    assert snapshot.service == "marshall_web"
    assert snapshot.requests == included
    assert snapshot.successes == successes
    assert snapshot.failures == included - successes
    assert snapshot.duration.count == included
    assert Enum.sum(snapshot.duration.bucket_counts) == included
    assert length(snapshot.duration.bucket_counts) == 8
  end

  test "endpoint telemetry counts a final response and exception without retaining metadata" do
    if Process.whereis(SLO) == nil, do: start_supervised!({SLO, path: nil})

    [{:slo, before, _, _, _, _, _, _, _, _, _, _, _, _}] = :ets.lookup(SLO, :slo)
    duration = System.convert_time_unit(8_000, :microsecond, :native)

    :telemetry.execute(
      [:phoenix, :endpoint, :stop],
      %{duration: duration},
      %{conn: %{status: 200, request_path: "/private?token=secret"}, token: "secret"}
    )

    :telemetry.execute(
      [:phoenix, :endpoint, :exception],
      %{duration: duration},
      %{conn: %{status: nil, request_path: "/private?token=secret"}, token: "secret"}
    )

    [{:slo, after_count, _, _, _, _, _, _, _, _, _, _, _, _}] = :ets.lookup(SLO, :slo)
    assert after_count == before + 2
    refute inspect(:ets.lookup(SLO, :slo)) =~ "secret"
  end

  test "actual endpoint excludes health and counts a completed browser response" do
    if Process.whereis(SLO) == nil, do: start_supervised!({SLO, path: nil})

    [{:slo, before, _, _, _, _, _, _, _, _, _, _, _, _}] = :ets.lookup(SLO, :slo)
    health = MarshallWeb.Endpoint.call(Plug.Test.conn(:get, "/health/live"), [])
    assert health.status == 200
    [{:slo, after_health, _, _, _, _, _, _, _, _, _, _, _, _}] = :ets.lookup(SLO, :slo)
    assert after_health == before

    response = MarshallWeb.Endpoint.call(Plug.Test.conn(:get, "/definitely-missing"), [])
    assert response.status == 404
    [{:slo, after_browser, _, _, _, _, _, _, _, _, _, _, _, _}] = :ets.lookup(SLO, :slo)
    assert after_browser == before + 1
  end
end
