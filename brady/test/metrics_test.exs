defmodule Brady.MetricsTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  test "concurrent observations retain only fixed aggregate values" do
    before = Brady.Metrics.snapshot()

    1..100
    |> Task.async_stream(fn _ ->
      Brady.Metrics.request(%{
        reason: :ok,
        cache: :hit,
        bytes_sent: 10,
        bytes_received: -1,
        url: "private-fixture",
        owner_id: "private-fixture"
      })
    end)
    |> Stream.run()

    after_sample = Brady.Metrics.snapshot()
    assert after_sample["requests"] == before["requests"] + 100
    assert after_sample["cache_hits"] == before["cache_hits"] + 100
    assert after_sample["bytes_sent"] == before["bytes_sent"] + 1000
    assert after_sample["bytes_received"] == before["bytes_received"]
    refute JSON.encode!(after_sample) =~ "private-fixture"
  end

  test "private atomic snapshot remains usable when cache metrics are unavailable" do
    root = Path.join(System.tmp_dir!(), "brady-metrics-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "metrics.json")
    slo_path = Path.join(root, "slo.json")
    :ok = Supervisor.terminate_child(Brady.Supervisor, Brady.Metrics)

    on_exit(fn ->
      Supervisor.restart_child(Brady.Supervisor, Brady.Metrics)
      File.rm_rf!(root)
    end)

    pid =
      start_supervised!(
        {Brady.Metrics,
         path: path,
         slo_path: slo_path,
         invocation: String.duplicate("a", 32),
         cache: :absent_fixture_cache}
      )

    # The call is ordered after the producer's initial publication message.
    GenServer.call(pid, :snapshot)
    data = path |> File.read!() |> JSON.decode!()
    assert data["version"] == 1
    assert data["invocation_id"] == String.duplicate("a", 32)
    assert Regex.match?(~r/\A[0-9a-f]{32}\z/, data["incarnation"])
    assert data["gauges"] == %{}
    assert data["counters"]["requests"] == 0
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    refute File.exists?(path <> ".tmp")
    slo = slo_path |> File.read!() |> JSON.decode!()
    assert slo["service"] == "brady"
    assert slo["requests"] == 0
    assert slo["successes"] == 0
    assert slo["failures"] == 0
    assert slo["duration"]["bucket_counts"] == List.duplicate(0, 8)
    assert Bitwise.band(File.stat!(slo_path).mode, 0o777) == 0o600
    refute File.exists?(slo_path <> ".tmp")
    stop_supervised!(Brady.Metrics)
  end

  # @cc [owner:ghuntley,label:verification] metrics-generated-case-custody
  # Each generated case and replay MUST begin with fresh counters, retire its
  # replacement Metrics process, and restore the application's supervised owner.
  property "generated admitted outcomes have closed cumulative SLO buckets" do
    :ok = Supervisor.terminate_child(Brady.Supervisor, Brady.Metrics)

    Hegel.on_cleanup(fn ->
      {:ok, _pid} = Supervisor.restart_child(Brady.Supervisor, Brady.Metrics)
    end)

    Overalls.HegelFixtures.start_supervised!({Brady.Metrics, []})

    observations =
      draw(
        "observations",
        list_of(
          {member_of([:ok, :upstream, :timeout, :internal, :policy, :invalid_request]),
           integer(0..12_000_000), boolean()},
          min_length: 1,
          max_length: 24
        )
      )

    before = Brady.Metrics.slo_snapshot()
    assert is_map(before)
    assert before.requests == 0

    for {reason, duration, unresolved?} <- observations do
      Brady.Metrics.request(%{
        reason: reason,
        duration_us: duration,
        attribution: if(unresolved?, do: :unresolved, else: :resolved),
        slo_admitted: :yes
      })
    end

    after_sample = Brady.Metrics.slo_snapshot()
    assert is_map(after_sample)

    admitted =
      Enum.filter(observations, fn {reason, _, unresolved?} ->
        !unresolved? and reason not in [:policy, :invalid_request]
      end)

    assert after_sample.requests - before.requests == length(admitted)

    assert after_sample.successes - before.successes ==
             Enum.count(admitted, fn {reason, _, _} -> reason == :ok end)

    assert after_sample.failures - before.failures ==
             Enum.count(admitted, fn {reason, _, _} -> reason != :ok end)

    assert after_sample.duration.count - before.duration.count == length(admitted)

    assert after_sample.duration.sum_us - before.duration.sum_us ==
             Enum.reduce(admitted, 0, fn {_, duration, _}, sum -> sum + duration end)

    assert Enum.zip_with(
             after_sample.duration.bucket_counts,
             before.duration.bucket_counts,
             &Kernel.-/2
           ) ==
             Enum.map(0..7, fn bucket ->
               Enum.count(admitted, fn {_, duration, _} ->
                 (Enum.find_index(after_sample.duration.explicit_bounds_us, &(duration <= &1)) ||
                    7) ==
                   bucket
               end)
             end)
  end

  test "missing attribution cannot create a trusted SLO outcome" do
    before = Brady.Metrics.slo_snapshot()
    Brady.Metrics.request(%{reason: :ok, duration_us: 1_000, slo_admitted: :yes})
    assert Brady.Metrics.slo_snapshot() == before
    Brady.Metrics.request(%{reason: :tls, duration_us: 1_000, attribution: :resolved})
    assert Brady.Metrics.slo_snapshot() == before
  end
end
